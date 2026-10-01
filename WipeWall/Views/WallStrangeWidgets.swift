import Foundation
import SwiftUI

struct WeekStripWallWidget: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30 * 60)) { context in
            let calendar = Calendar.current
            let interval = calendar.dateInterval(of: .weekOfYear, for: context.date)
            let start = interval?.start ?? context.date
            StrangeWidgetShell(title: "This week") {
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { offset in
                        let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                        let today = calendar.isDate(date, inSameDayAs: context.date)
                        VStack(spacing: 5) {
                            Text(Self.weekday.string(from: date).uppercased())
                                .font(.custom("Helvetica-Bold", size: 10))
                            Text("\(calendar.component(.day, from: date))")
                                .font(.custom(today ? "Helvetica-Bold" : "Helvetica", size: 20))
                            Rectangle()
                                .fill(today ? Color.black : Color.clear)
                                .frame(height: 2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEEE"
        return formatter
    }()
}

struct ThreeMonthsWallWidget: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60 * 60)) { context in
            StrangeWidgetShell(title: "Three months") {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(-1...1, id: \.self) { offset in
                        MiniMonth(date: Calendar.current.date(byAdding: .month, value: offset, to: context.date) ?? context.date)
                    }
                }
            }
        }
    }
}

private struct MiniMonth: View {
    let date: Date
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)

    var body: some View {
        let calendar = Calendar.current
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<2
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let blanks = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        VStack(spacing: 5) {
            Text(Self.month.string(from: date).uppercased())
                .font(.custom("Helvetica-Bold", size: 10))
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(0..<(blanks + range.count), id: \.self) { index in
                    if index < blanks {
                        Color.clear.frame(height: 13)
                    } else {
                        let day = index - blanks + 1
                        Text("\(day)")
                            .font(.custom("Helvetica", size: 9))
                            .frame(maxWidth: .infinity, minHeight: 13)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM"
        return formatter
    }()
}

struct WeekNumberWallWidget: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60 * 60)) { context in
            StrangeWidgetShell(title: "Week number") {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("\(Calendar(identifier: .iso8601).component(.weekOfYear, from: context.date))")
                        .font(.custom("Helvetica-Bold", size: 62))
                    Text("of 52-ish")
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(.black.opacity(0.5))
                }
            }
        }
    }
}

struct DayOfYearWallWidget: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60 * 60)) { context in
            let calendar = Calendar.current
            let day = calendar.ordinality(of: .day, in: .year, for: context.date) ?? 1
            let total = calendar.range(of: .day, in: .year, for: context.date)?.count ?? 365
            StrangeWidgetShell(title: "Day of year") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(day) / \(total)")
                        .font(.custom("Helvetica-Bold", size: 34))
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.12))
                            Rectangle().fill(Color.black)
                                .frame(width: proxy.size.width * CGFloat(day) / CGFloat(total))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
    }
}

struct WallGeneratedStrangeWidget: View {
    let kind: WallWidgetKind
    @State private var line = ""
    @State private var isLoading = false
    @State private var generation = 0

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            Group {
                if kind == .desireOfOther {
                    Text(line.isEmpty ? fallback : line)
                        .font(.custom("Helvetica-Bold", size: 24))
                        .lineSpacing(2)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .accessibilityLabel(line.isEmpty ? fallback : line)
                    .padding(13)
                } else {
                    StrangeWidgetShell(title: kind.title) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(line.isEmpty ? fallback : line)
                                .font(.custom(kind == .lacanianSignifier ? "Helvetica-Bold" : "Helvetica", size: kind == .lacanianSignifier ? 24 : 16))
                                .lineSpacing(2)
                                .minimumScaleFactor(0.78)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                            HStack {
                                Text("LLM / FOR REFLECTION ONLY")
                                    .font(.custom("Helvetica-Bold", size: 8))
                                    .tracking(0.6)
                                    .foregroundColor(.black.opacity(0.38))
                                Spacer()
                                Button {
                                    generation += 1
                                } label: {
                                    if isLoading {
                                        ProgressView().scaleEffect(0.65)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                }
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.black)
                                .buttonStyle(.plain)
                                .accessibilityLabel("Generate another \(kind.title)")
                            }
                        }
                    }
                }
            }
            .task(id: "\(WallOracleConfiguration.dayKey(for: context.date))-\(generation)") {
                isLoading = true
                line = await WallOracleService.shared.line(for: kind, nonce: generation)
                isLoading = false
            }
        }
    }

    private var fallback: String {
        switch kind {
        case .astrologicalWeather: return "The room is between aspects. Avoid replying all."
        case .mercuryMemo: return "Mercury left no forwarding address."
        case .lacanianSignifier: return "the almost"
        case .mirrorStage: return "You recognize yourself, but the image has better posture."
        case .desireOfOther: return "to be interrupted"
        case .dreamResidue: return "A hallway, a receipt, someone else’s coat."
        case .defenseMechanism: return "Intellectualization, but make it decorative."
        case .projection: return "The chair is not judging your calendar."
        case .superegoForecast: return "High pressure, clearing after dinner."
        case .strangeOracle: return "Do it, but put it somewhere reversible."
        case .unreliableNarrator: return "By noon, she had already decided this was foreshadowing."
        default: return "The sign is loading."
        }
    }
}

enum WallOracleConfiguration {
    static let model = "gpt-5.6-luna"
    static let temperature = 1.8

    static func dayKey(for date: Date = Date(), calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return 0 }
        return year * 10_000 + month * 100 + day
    }
}

struct DailyHoroscopesWallWidget: View {
    @StateObject private var service = WallHoroscopeService()

    private let people: [GoonPerson] = [.casey, .drew, .alex, .blake, .ellis]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(people.enumerated()), id: \.element) { index, person in
                HStack(alignment: .top, spacing: 12) {
                    AnimatedGoonName(person: person)
                        .frame(width: 96, alignment: .leading)

                    Text(service.readings[person] ?? "The sky is checking its notes.")
                        .font(.custom("Helvetica", size: 12.5))
                        .foregroundColor(.black)
                        .lineSpacing(2)
                        .lineLimit(7)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(person.rawValue). \(service.readings[person] ?? "Horoscope loading")")

                if index < people.count - 1 {
                    Rectangle()
                        .fill(Color.black.opacity(0.13))
                        .frame(height: 1)
                }
            }
        }
        .padding(13)
        .task { await service.maintainDailyReadings() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { _ = await service.refreshIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { _ = await service.refreshIfNeeded(force: true) }
        }
    }
}

struct WallHoroscopeReading: Codable, Equatable {
    let date: String
    let sign: String
    let horoscope: String
}

enum WallHoroscopeAPI {
    static let endpoint = URL(string: "https://freehoroscopeapi.com/api/v1/get-horoscope/daily")!

    private static var wallCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    static func sign(for person: GoonPerson) -> String {
        switch person {
        case .casey: return "aquarius"
        case .drew: return "pisces"
        case .alex: return "cancer"
        case .blake: return "sagittarius"
        case .ellis: return "taurus"
        }
    }

    static func request(
        for person: GoonPerson,
        day: String = dayKey()
    ) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "sign", value: sign(for: person)),
            // The endpoint occasionally sits behind a stale intermediary
            // cache. The day key changes only once per day but prevents
            // yesterday's response from being reused.
            URLQueryItem(name: "wall_day", value: day)
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    static func reading(from data: Data) -> WallHoroscopeReading? {
        struct Envelope: Decodable {
            let data: WallHoroscopeReading
        }
        guard let reading = try? JSONDecoder().decode(Envelope.self, from: data).data else { return nil }
        let cleaned = reading.horoscope
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return WallHoroscopeReading(date: reading.date, sign: reading.sign, horoscope: cleaned)
    }

    static func isCurrentProviderDate(_ providerDate: String, localDay: String) -> Bool {
        guard providerDate == localDay || providerDate == nextDay(after: localDay) else { return false }
        return true
    }

    private static func nextDay(after day: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = wallCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day),
              let next = wallCalendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return formatter.string(from: next)
    }

    static func dayKey(for date: Date = Date(), calendar: Calendar = wallCalendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func nextDailyRefresh(after date: Date = Date(), calendar: Calendar = wallCalendar) -> Date {
        let startOfToday = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? date.addingTimeInterval(24 * 60 * 60)
        return calendar.date(byAdding: .second, value: 5, to: nextDay) ?? nextDay
    }
}

@MainActor
final class WallHoroscopeService: ObservableObject {
    @Published private(set) var readings: [GoonPerson: String] = [:]
    @Published private(set) var isLoading = false

    private struct Cache: Codable {
        var date: String
        var readings: [GoonPerson: String]
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let persistenceKey: String
    private var cachedDate = ""

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        persistenceKey: String = "wall.daily-horoscopes.v1"
    ) {
        self.defaults = defaults
        self.session = session
        self.persistenceKey = persistenceKey
        if let data = defaults.data(forKey: persistenceKey),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            cachedDate = cache.date
            readings = cache.readings
        }
    }

    func maintainDailyReadings() async {
        while !Task.isCancelled {
            let isCurrent = await refreshIfNeeded()
            let nextRefresh = isCurrent
                ? WallHoroscopeAPI.nextDailyRefresh()
                : Date().addingTimeInterval(30 * 60)
            let delay = max(1, nextRefresh.timeIntervalSinceNow)
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    @discardableResult
    func refreshIfNeeded(force: Bool = false) async -> Bool {
        let today = WallHoroscopeAPI.dayKey()
        let hasEveryReading = GoonPerson.allCases.allSatisfy { readings[$0]?.isEmpty == false }
        guard force || cachedDate != today || !hasEveryReading else { return true }
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }

        let session = session
        let fetched = await withTaskGroup(of: (GoonPerson, WallHoroscopeReading?).self) { group in
            for person in GoonPerson.allCases {
                group.addTask {
                    do {
                        let (data, response) = try await session.data(
                            for: WallHoroscopeAPI.request(for: person, day: today)
                        )
                        guard let response = response as? HTTPURLResponse,
                              200..<300 ~= response.statusCode else { return (person, nil) }
                        // The provider rolls its own `date` field at midnight
                        // UTC, four hours before Wall's New York day changes.
                        // Treat a valid daily response as the local day's fetch;
                        // the local cache key still advances at New York midnight.
                        return (person, WallHoroscopeAPI.reading(from: data))
                    } catch {
                        return (person, nil)
                    }
                }
            }

            var values: [(GoonPerson, WallHoroscopeReading?)] = []
            for await value in group { values.append(value) }
            return values
        }

        var successful = 0
        for (person, reading) in fetched {
            guard let reading,
                  WallHoroscopeAPI.isCurrentProviderDate(reading.date, localDay: today) else { continue }
            readings[person] = reading.horoscope
            successful += 1
        }

        guard successful > 0 else { return false }
        if successful == GoonPerson.allCases.count {
            cachedDate = today
        }
        if let data = try? JSONEncoder().encode(Cache(date: cachedDate, readings: readings)) {
            defaults.set(data, forKey: persistenceKey)
        }
        return successful == GoonPerson.allCases.count
    }
}

private struct StrangeWidgetShell<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.custom("Helvetica-Bold", size: 11))
                .tracking(0.8)
            Rectangle().fill(Color.black).frame(height: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundColor(.black)
        .padding(13)
    }
}

private actor WallOracleService {
    static let shared = WallOracleService()
    private var cache: [String: String] = [:]
    private let defaults = UserDefaults.standard

    func line(for kind: WallWidgetKind, nonce: Int) async -> String {
        let day = WallOracleConfiguration.dayKey()
        let key = "\(kind.rawValue)-\(day)-\(nonce)"
        if let cached = cache[key] { return cached }

        let persistedDayKey = "wall.oracle.\(kind.rawValue).day"
        let persistedTextKey = "wall.oracle.\(kind.rawValue).text"
        if nonce == 0,
           defaults.integer(forKey: persistedDayKey) == day,
           let persisted = defaults.string(forKey: persistedTextKey),
           !persisted.isEmpty {
            cache[key] = persisted
            return persisted
        }

        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            return "The oracle misplaced its endpoint."
        }
        let payload: [String: Any] = [
            "model": WallOracleConfiguration.model,
            "store": false,
            "reasoning": ["effort": "none"],
            "temperature": WallOracleConfiguration.temperature,
            "max_output_tokens": 90,
            "instructions": "You write one original line for a strange wall widget. Be dry, specific, elegant, surprising, and a little funny. Vary imagery aggressively from day to day. Never mention brass, metal, mirrors, hallways, rooms, keys, clocks, or receipts. Never diagnose the reader, claim clinical authority, or present astrology as factual prediction. Return only the requested text, with no title, label, quotation marks, prefix, or explanation.",
            "input": prompt(for: kind)
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return "The signifier refused serialization."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(RealtimeSecrets.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode,
                  let text = Self.outputText(from: data)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return "The oracle is withholding comment."
            }
            let clipped = String(text.prefix(220))
            cache[key] = clipped
            if nonce == 0 {
                defaults.set(day, forKey: persistedDayKey)
                defaults.set(clipped, forKey: persistedTextKey)
            }
            return clipped
        } catch {
            return "The unconscious is temporarily offline."
        }
    }

    private func prompt(for kind: WallWidgetKind) -> String {
        let date = Self.date.string(from: Date())
        switch kind {
        case .astrologicalWeather:
            return "Write a one-sentence playful astrological weather bulletin for \(date), without needing a birth chart."
        case .mercuryMemo:
            return "Write a terse office memo from the planet Mercury to the person reading a wall iPad."
        case .lacanianSignifier:
            return "Invent a two-to-five-word Lacanian signifier of the day. Evocative, not explanatory."
        case .mirrorStage:
            return "Write one wry sentence about the mirror stage happening in an ordinary apartment today."
        case .desireOfOther:
            return "Invent today's desire of the Other as a concrete, strange desire phrase of 3 to 12 words. Output only the desire itself. Do not write a sentence, introduce it, explain it, or begin with 'you want', 'the room', or 'the Other'."
        case .dreamResidue:
            return "Generate a compact surreal dream fragment containing three concrete objects."
        case .defenseMechanism:
            return "Name a harmless everyday defense mechanism for today and describe it in one funny sentence. Do not diagnose anyone."
        case .projection:
            return "Write one dry sentence about a feeling being projected onto a household object."
        case .superegoForecast:
            return "Write a weather forecast for the superego in one sentence."
        case .strangeOracle:
            return "Give one oddly precise but low-stakes oracle sentence for today."
        case .unreliableNarrator:
            return "Rewrite an ordinary moment today as one sentence from an unreliable literary narrator."
        default:
            return "Write one strange sentence for \(date)."
        }
    }

    private static func outputText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [[String: Any]] else { return nil }
        for item in output where item["type"] as? String == "message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String { return text }
            }
        }
        return nil
    }

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter
    }()
}
