import Foundation

enum GoonLogAction: String, Codable {
    case add
    case remove
}

struct GoonLogEvent: Codable, Equatable {
    let id: UUID
    let person: GoonPerson
    let action: GoonLogAction
    let occurredAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case person
        case action
        case occurredAt = "occurred_at"
    }
}

protocol GoonEventRecording {
    func record(_ event: GoonLogEvent)
}

final class GoonLogClient: GoonEventRecording {
    static let shared = GoonLogClient()

    private let baseURL = WallConfiguration.serverURL
    private let queue = DispatchQueue(label: "wall.goon.log")
    private var retryTimer: DispatchSourceTimer?

    func start() {
        queue.async { [weak self] in
            self?.ensureDirectory()
            self?.retryPending()
            self?.startRetryTimer()
        }
    }

    func record(_ event: GoonLogEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            ensureDirectory()
            let file = pendingDirectory.appendingPathComponent("\(event.id.uuidString).json")
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(event).write(to: file, options: .atomic)
                upload(file)
            } catch {
                // The iPad tally still succeeds; only successfully queued files retry.
            }
        }
    }

    private var pendingDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingGoonEvents", isDirectory: true)
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: pendingDirectory,
            withIntermediateDirectories: true
        )
    }

    private func startRetryTimer() {
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 60)
        timer.setEventHandler { [weak self] in self?.retryPending() }
        timer.resume()
        retryTimer = timer
    }

    private func retryPending() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension.lowercased() == "json" {
            upload(file)
        }
    }

    private func upload(_ file: URL) {
        guard let body = try? Data(contentsOf: file), body.count <= 4_096 else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/device/goons"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(KeychainToken.getOrCreate())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Wall iPad", forHTTPHeaderField: "X-Wall-Device")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 200 || status == 201 {
                try? FileManager.default.removeItem(at: file)
            }
        }.resume()
    }
}
