import Foundation

enum WallMusicSource: String, CaseIterable, Codable {
    case spotify
    case soundcloud

    static func toolSelection(_ value: Any?) -> WallMusicSource {
        guard let rawValue = value as? String else { return .spotify }
        return WallMusicSource(rawValue: rawValue.lowercased()) ?? .spotify
    }
}
