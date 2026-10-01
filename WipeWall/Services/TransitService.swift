import Foundation

struct TransitAlert: Identifiable, Equatable {
    let id: String
    let routes: [String]
    let headline: String
    let kind: String
}

enum WallTransitScope {
    static let routes: Set<String> = ["L", "M"]

    static func alerts(from alerts: [TransitAlert]) -> [TransitAlert] {
        alerts.compactMap { alert in
            let scopedRoutes = alert.routes.filter {
                routes.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            }
            guard !scopedRoutes.isEmpty else { return nil }
            return TransitAlert(
                id: alert.id,
                routes: scopedRoutes,
                headline: alert.headline,
                kind: alert.kind
            )
        }
    }
}

struct TransitService {
    static let endpoint = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts.json")!

    func fetchActiveSubwayAlerts(now: Date = Date()) async throws -> [TransitAlert] {
        let (data, response) = try await URLSession.shared.data(from: Self.endpoint)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try Self.parse(data: data, now: now)
    }

    static func parse(data: Data, now: Date) throws -> [TransitAlert] {
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        let timestamp = now.timeIntervalSince1970

        return feed.entity.compactMap { entity in
            let alert = entity.alert
            guard alert.isActive(at: timestamp) else { return nil }
            let kind = alert.mercury?.alertType ?? ""
            let routes = Array(Set(alert.informedEntity.compactMap(\.routeID))).sorted()
            guard !routes.isEmpty, !alert.englishHeadline.isEmpty else { return nil }
            return TransitAlert(
                id: entity.id,
                routes: routes,
                headline: alert.englishHeadline.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""),
                kind: kind
            )
        }
        .sorted { severity($0.kind) > severity($1.kind) }
    }

    private static func severity(_ kind: String) -> Int {
        let value = kind.lowercased()
        if value.contains("suspend") || value.contains("no service") { return 3 }
        if value.contains("delay") { return 2 }
        return 1
    }
}

private struct Feed: Decodable {
    let entity: [Entity]

    struct Entity: Decodable {
        let id: String
        let alert: Alert
    }

    struct Alert: Decodable {
        let activePeriod: [ActivePeriod]
        let informedEntity: [InformedEntity]
        let headerText: TranslationSet?
        let mercury: MercuryAlert?

        enum CodingKeys: String, CodingKey {
            case activePeriod = "active_period"
            case informedEntity = "informed_entity"
            case headerText = "header_text"
            case mercury = "transit_realtime.mercury_alert"
        }

        var englishHeadline: String {
            headerText?.translation.first(where: { $0.language == "en" })?.text
                ?? headerText?.translation.first?.text
                ?? ""
        }

        func isActive(at timestamp: TimeInterval) -> Bool {
            activePeriod.isEmpty || activePeriod.contains { period in
                let afterStart = period.start.map { timestamp >= $0 } ?? true
                let beforeEnd = period.end.map { timestamp <= $0 } ?? true
                return afterStart && beforeEnd
            }
        }
    }

    struct ActivePeriod: Decodable {
        let start: TimeInterval?
        let end: TimeInterval?
    }

    struct InformedEntity: Decodable {
        let routeID: String?
        enum CodingKeys: String, CodingKey { case routeID = "route_id" }
    }

    struct TranslationSet: Decodable {
        let translation: [Translation]
    }

    struct Translation: Decodable {
        let text: String
        let language: String?
    }

    struct MercuryAlert: Decodable {
        let alertType: String?
        enum CodingKeys: String, CodingKey { case alertType = "alert_type" }
    }
}
