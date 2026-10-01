import Foundation

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var weather: WeatherSnapshot?
    @Published private(set) var transitAlerts: [TransitAlert] = []

    private let weatherService = WeatherService()
    private let transitService = TransitService()
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let weatherResult = weatherService.fetchNYCWeather()
        async let transitResult = transitService.fetchActiveSubwayAlerts()

        if let latestWeather = try? await weatherResult {
            weather = latestWeather
        }
        if let latestAlerts = try? await transitResult {
            transitAlerts = latestAlerts
        }
    }
}
