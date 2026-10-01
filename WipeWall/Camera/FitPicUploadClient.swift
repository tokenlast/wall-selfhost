import Foundation
import Security

enum FitPicCaptureSource: String, Codable {
    case automatic
    case manual
    case photoBooth = "photo_booth"
}

struct FitPicUploadReceipt: Decodable, Equatable {
    let saved: Bool
    let name: String
}

private struct PendingFitPicMetadata: Codable {
    let source: FitPicCaptureSource
    let photoBoothNight: String?
}

final class FitPicUploadClient {
    private let baseURL = WallConfiguration.serverURL
    private let queue = DispatchQueue(label: "wall.fitpic.upload")
    private var retryTimer: DispatchSourceTimer?

    func start() {
        queue.async { [weak self] in
            self?.ensureDirectories()
            self?.enroll()
            self?.retryPending()
            self?.startRetryTimer()
        }
    }

    func enqueue(
        _ data: Data,
        source: FitPicCaptureSource,
        photoBoothNight: String? = nil,
        completion: @escaping (FitPicUploadReceipt?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            ensureDirectories()
            let identifier = UUID().uuidString
            let file = pendingDirectory.appendingPathComponent("\(identifier).jpg")
            let metadataFile = pendingDirectory.appendingPathComponent("\(identifier).json")
            do {
                try data.write(to: file, options: .atomic)
                let metadata = PendingFitPicMetadata(
                    source: source,
                    photoBoothNight: source == .photoBooth ? photoBoothNight : nil
                )
                try JSONEncoder().encode(metadata).write(to: metadataFile, options: .atomic)
                upload(file) { receipt in completion(receipt) }
            } catch {
                completion(nil)
            }
        }
    }

    private var pendingDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingFitPics", isDirectory: true)
    }

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
    }

    private func startRetryTimer() {
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.enroll()
            self?.retryPending()
        }
        timer.resume()
        retryTimer = timer
    }

    private func retryPending() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension.lowercased() == "jpg" { upload(file, completion: nil) }
    }

    private func enroll() {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/device/enroll"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": deviceToken,
            "label": "Wall iPad"
        ])
        URLSession.shared.dataTask(with: request).resume()
    }

    private func upload(_ file: URL, completion: ((FitPicUploadReceipt?) -> Void)?) {
        let metadataFile = file.deletingPathExtension().appendingPathExtension("json")
        let metadata = (try? Data(contentsOf: metadataFile))
            .flatMap { try? JSONDecoder().decode(PendingFitPicMetadata.self, from: $0) }
            ?? PendingFitPicMetadata(source: .manual, photoBoothNight: nil)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/device/photos"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("Wall iPad", forHTTPHeaderField: "X-Wall-Device")
        request.setValue(metadata.source.rawValue, forHTTPHeaderField: "X-Wall-Capture-Source")
        if let night = metadata.photoBoothNight {
            request.setValue(night, forHTTPHeaderField: "X-Wall-Photo-Booth-Night")
        }
        URLSession.shared.uploadTask(with: request, fromFile: file) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let saved = status == 201
            let receipt = data.flatMap { try? JSONDecoder().decode(FitPicUploadReceipt.self, from: $0) }
            let permanentlyRejected = status == 400 || status == 415 || status == 422
            if saved || permanentlyRejected {
                self.movePendingItemToTrash(file)
                self.movePendingItemToTrash(metadataFile)
            }
            completion?(saved ? receipt : nil)
        }.resume()
    }

    private func movePendingItemToTrash(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let trash = pendingDirectory.appendingPathComponent("Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent("\(UUID().uuidString)-\(file.lastPathComponent)")
        try? FileManager.default.moveItem(at: file, to: destination)
    }

    private var deviceToken: String {
        KeychainToken.getOrCreate()
    }
}

enum KeychainToken {
    private static let service = "org.example.wall.wipewall.fitpic"
    private static let account = "device-token"

    static func getOrCreate() -> String {
        if let existing = read() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        KeychainToken.write(token)
        return token
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var query = identity
        query.merge([
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]) { _, new in new }
        SecItemDelete(identity as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
