import Foundation

struct WeatherPeriod: Identifiable, Equatable {
    let time: Date
    let temperature: Double
    let rainChance: Int
    let weatherCode: Int

    var id: Date { time }
}

struct WeatherSnapshot: Equatable {
    let currentTemperature: Double
    let currentCode: Int
    let high: Double
    let low: Double
    let rainChance: Int
    let rainAmount: Double
    let periods: [WeatherPeriod]

    var expectsRain: Bool { rainAmount >= 0.01 || rainChance >= 25 }
}

struct WeatherService {
    private struct Response: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature_2m: Double
            let weather_code: Int
        }

        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]
            let precipitation_probability: [Int]
            let weather_code: [Int]
        }

        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let precipitation_probability_max: [Int]
            let rain_sum: [Double]
        }
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    func fetchNYCWeather() async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: "40.7128"),
            URLQueryItem(name: "longitude", value: "-74.0060"),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,rain_sum"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "precipitation_unit", value: "inch"),
            URLQueryItem(name: "timezone", value: "America/New_York"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
        return try Self.snapshot(from: data)
    }

    static func snapshot(from data: Data) throws -> WeatherSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let daily = response.daily
        guard let high = daily.temperature_2m_max.first,
              let low = daily.temperature_2m_min.first,
              let chance = daily.precipitation_probability_max.first,
              let amount = daily.rain_sum.first else {
            throw URLError(.cannotParseResponse)
        }

        let dates = response.hourly.time.map { Self.localDate(from: $0) }
        let count = [
            dates.count,
            response.hourly.temperature_2m.count,
            response.hourly.precipitation_probability.count,
            response.hourly.weather_code.count
        ].min() ?? 0
        let currentDate = Self.localDate(from: response.current.time) ?? Date()
        var periods: [WeatherPeriod] = []
        for index in 0..<count {
            guard let date = dates[index], date >= currentDate else { continue }
            let hour = Self.newYorkCalendar.component(.hour, from: date)
            guard hour.isMultiple(of: 2) else { continue }
            periods.append(WeatherPeriod(
                time: date,
                temperature: response.hourly.temperature_2m[index],
                rainChance: response.hourly.precipitation_probability[index],
                weatherCode: response.hourly.weather_code[index]
            ))
            if periods.count == 6 { break }
        }

        return WeatherSnapshot(
            currentTemperature: response.current.temperature_2m,
            currentCode: response.current.weather_code,
            high: high,
            low: low,
            rainChance: chance,
            rainAmount: amount,
            periods: periods
        )
    }

    private static var newYorkCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private static func localDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: value)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
    }
}

enum WeatherCodePresentation {
    static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max"
        case 1, 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...67, 80...82: return "cloud.rain"
        case 71...77, 85, 86: return "snowflake"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }

    static func label(for code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1, 2: return "partly cloudy"
        case 3: return "cloudy"
        case 45, 48: return "fog"
        case 51...57: return "drizzle"
        case 61...67, 80...82: return "rain"
        case 71...77, 85, 86: return "snow"
        case 95...99: return "storm"
        default: return "cloudy"
        }
    }
}
