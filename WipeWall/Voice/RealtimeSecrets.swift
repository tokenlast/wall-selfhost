import Foundation

// Development-only configurable key. Prefer a short-lived token broker for distribution.
enum RealtimeSecrets {
    static var apiKey: String { ProcessInfo.processInfo.environment["WALL_REALTIME_API_KEY"] ?? Bundle.main.object(forInfoDictionaryKey: "WallRealtimeAPIKey") as? String ?? "" }
}
