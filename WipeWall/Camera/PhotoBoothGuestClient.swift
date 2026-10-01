import Foundation

struct PhotoBoothEmailPrompt: Identifiable, Equatable {
    let id = UUID()
    let photoName: String
    let night: String
}

enum PhotoBoothEmailPolicy {
    static let untouchedDismissDelay: TimeInterval = 20
    static let typingIdleDelay: TimeInterval = 10

    static func isPlausible(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254,
              let at = value.firstIndex(of: "@"),
              at != value.startIndex,
              value.index(after: at) != value.endIndex else { return false }
        return value[value.index(after: at)...].contains(".")
    }
}

final class PhotoBoothGuestClient {
    static let shared = PhotoBoothGuestClient()
    private let baseURL = WallConfiguration.serverURL

    func save(email: String, prompt: PhotoBoothEmailPrompt) async -> Bool {
        guard PhotoBoothEmailPolicy.isPlausible(email) else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/device/photo-booth/guests"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(KeychainToken.getOrCreate())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            "photo_name": prompt.photoName,
            "night": prompt.night
        ])
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse else { return false }
        return response.statusCode == 201
    }
}
