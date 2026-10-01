import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Spotify catalog and account reads stay behind Wall's approved-device broker.
struct SpotifyCatalogClient {
    static let shared = SpotifyCatalogClient()
    let session: URLSession
    let deviceToken: () -> String?

    init(session: URLSession = .shared, deviceToken: @escaping () -> String? = KeychainToken.read) {
        self.session = session
        self.deviceToken = deviceToken
    }

    func searchTracks(query: String) async throws -> [WallMusicSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        guard query.count <= 160 else { throw Failure(message: "Keep the Spotify search under 160 characters.") }
        guard let token = deviceToken(), !token.isEmpty else {
            throw Failure(message: "Wall’s device connection needs to be restored before searching Spotify.")
        }
        var url = URLComponents(url: WallConfiguration.serverURL.appendingPathComponent("api/device/spotify/search"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "Wall received an unreadable Spotify response.")
        }
        guard 200..<300 ~= http.statusCode else {
            struct ServerError: Decodable { let error: String }
            let detail = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw Failure(message: detail.map { String($0.prefix(200)) }
                ?? "Wall’s Spotify catalog is unavailable (HTTP \(http.statusCode)).")
        }
        return try WallMusicSearchModel.results(in: data)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

struct SpotifyUserPlaylist: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let uri: String
    let ownerName: String
    let artworkURL: URL?
    let trackCount: Int
}

struct SpotifyCloudAccountClient {
    struct Status: Decodable {
        let connected: Bool
        let displayName: String

        private enum CodingKeys: String, CodingKey {
            case connected
            case displayName = "display_name"
        }
    }

    private struct PlaylistsEnvelope: Decodable { let playlists: [SpotifyUserPlaylist] }
    private struct TracksEnvelope: Decodable { let references: [String] }

    let session: URLSession
    let deviceToken: () -> String?

    init(session: URLSession = .shared, deviceToken: @escaping () -> String? = KeychainToken.read) {
        self.session = session
        self.deviceToken = deviceToken
    }

    func status() async throws -> Status {
        try await get(path: "status", as: Status.self)
    }

    func playlists() async throws -> [SpotifyUserPlaylist] {
        try await get(path: "playlists", as: PlaylistsEnvelope.self).playlists
    }

    func tracks(in playlist: SpotifyUserPlaylist) async throws -> [SpotifyTrackReference] {
        let envelope = try await get(path: "playlists/\(playlist.id)/tracks", as: TracksEnvelope.self)
        let references = envelope.references.compactMap { SpotifyTrackResolver.reference(in: $0) }
        guard !references.isEmpty else { throw SpotifyAccountFailure.emptyPlaylist }
        return references
    }

    private func get<Response: Decodable>(path: String, as: Response.Type) async throws -> Response {
        guard let token = deviceToken(), !token.isEmpty else {
            throw SpotifyAccountFailure.missingRefreshToken
        }
        guard let url = URL(string: "api/device/spotify/account/\(path)", relativeTo: WallConfiguration.serverURL.appendingPathComponent("")) else {
            throw SpotifyAccountFailure.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SpotifyAccountFailure.invalidResponse
        }
        guard 200..<300 ~= response.statusCode else {
            throw SpotifyAccountFailure.httpStatus(response.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private enum SpotifyAccountFailure: LocalizedError {
    case invalidAuthorization
    case authorizationCancelled
    case invalidResponse
    case httpStatus(Int)
    case missingRefreshToken
    case emptyPlaylist

    var errorDescription: String? {
        switch self {
        case .invalidAuthorization: return "Spotify could not finish account authorization."
        case .authorizationCancelled: return "Spotify connection cancelled."
        case .invalidResponse: return "Spotify returned an unreadable response."
        case let .httpStatus(status): return "Spotify is unavailable (HTTP \(status))."
        case .missingRefreshToken: return "Connect Spotify in Wall settings to search and play its catalog."
        case .emptyPlaylist: return "That Spotify playlist has no playable tracks."
        }
    }
}

@MainActor
final class SpotifyAccountService: NSObject, ObservableObject {
    static let shared = SpotifyAccountService()

    static var clientID: String { Bundle.main.object(forInfoDictionaryKey: "WallSpotifyClientID") as? String ?? "" }
    static let redirectURI = "wall-spotify-login://callback"
    static let callbackScheme = "wall-spotify-login"

    @Published private(set) var isConnected = false
    @Published private(set) var isWorking = false
    @Published private(set) var displayName = ""
    @Published private(set) var playlists: [SpotifyUserPlaylist] = []
    @Published private(set) var status = "Spotify not connected"

    private let session: URLSession
    private let cloudClient: SpotifyCloudAccountClient
    private var usesCloudAccount = false
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var authorizationSession: ASWebAuthenticationSession?
    private var pendingVerifier = ""
    private var pendingState = ""
    private var hasAttemptedRestore = false

    init(session: URLSession = .shared, cloudClient: SpotifyCloudAccountClient? = nil) {
        self.session = session
        self.cloudClient = cloudClient ?? SpotifyCloudAccountClient(session: session)
        super.init()
    }

    func restore() async {
        guard !hasAttemptedRestore else {
            if isConnected, playlists.isEmpty { await loadPlaylists() }
            return
        }
        hasAttemptedRestore = true
        isWorking = true
        status = "Connecting Spotify…"
        do {
            let cloud = try await cloudClient.status()
            if cloud.connected {
                usesCloudAccount = true
                isConnected = true
                displayName = cloud.displayName
                playlists = try await cloudClient.playlists()
                status = playlists.isEmpty ? "No Spotify playlists" : "\(playlists.count) Spotify playlists"
                isWorking = false
                return
            }
        } catch {}
        guard SpotifyRefreshTokenStore.read() != nil else {
            isWorking = false
            status = "Connect Spotify in your Wall server’s browser workspace"
            return
        }
        do {
            usesCloudAccount = false
            try await refreshAccessToken()
            try await loadProfileAndPlaylists()
        } catch {
            clearSession(message: error.localizedDescription)
        }
        isWorking = false
    }

    func connect() {
        guard !isWorking else { return }
        guard !Self.clientID.isEmpty else {
            status = "Set your Spotify app client ID before using native sign-in, or connect through the Wall server."
            return
        }
        pendingVerifier = Self.randomURLSafeString(byteCount: 64)
        pendingState = Self.randomURLSafeString(byteCount: 24)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(pendingVerifier.utf8))))

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: pendingState),
            URLQueryItem(
                name: "scope",
                value: "playlist-read-private playlist-read-collaborative user-read-private"
            ),
            URLQueryItem(name: "show_dialog", value: "true")
        ]
        guard let authorizationURL = components.url else {
            status = SpotifyAccountFailure.invalidAuthorization.localizedDescription
            return
        }

        isWorking = true
        status = "Opening Spotify…"
        let auth = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: Self.callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationSession = nil
                if let authenticationError = error as? ASWebAuthenticationSessionError,
                   authenticationError.code == .canceledLogin {
                    self.isWorking = false
                    self.status = SpotifyAccountFailure.authorizationCancelled.localizedDescription
                    return
                }
                guard let callbackURL,
                      let values = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                      values.first(where: { $0.name == "state" })?.value == self.pendingState,
                      let code = values.first(where: { $0.name == "code" })?.value else {
                    self.isWorking = false
                    self.status = SpotifyAccountFailure.invalidAuthorization.localizedDescription
                    return
                }
                await self.exchangeAuthorizationCode(code)
            }
        }
        auth.presentationContextProvider = self
        auth.prefersEphemeralWebBrowserSession = false
        authorizationSession = auth
        if !auth.start() {
            authorizationSession = nil
            isWorking = false
            status = SpotifyAccountFailure.invalidAuthorization.localizedDescription
        }
    }

    func disconnect() {
        authorizationSession?.cancel()
        authorizationSession = nil
        SpotifyRefreshTokenStore.delete()
        usesCloudAccount = false
        accessToken = nil
        accessTokenExpiry = .distantPast
        hasAttemptedRestore = true
        isConnected = false
        isWorking = false
        displayName = ""
        playlists = []
        status = "Spotify not connected"
    }

    func searchTracks(query: String) async throws -> [WallMusicSearchResult] {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "10")
        ]
        let response: WallMusicSearchEnvelope = try await get(components.url!)
        return response.results
    }

    func loadPlaylists() async {
        guard !isWorking else { return }
        isWorking = true
        status = "Loading Spotify playlists…"
        do {
            playlists = usesCloudAccount ? try await cloudClient.playlists() : try await fetchPlaylists()
            isConnected = true
            status = playlists.isEmpty ? "No Spotify playlists" : "\(playlists.count) Spotify playlists"
        } catch {
            status = error.localizedDescription
        }
        isWorking = false
    }

    func play(_ playlist: SpotifyUserPlaylist) async -> Bool {
        guard isConnected, !isWorking else { return false }
        isWorking = true
        status = "playing…"
        do {
            let references = usesCloudAccount
                ? try await cloudClient.tracks(in: playlist)
                : try await fetchTracks(in: playlist)
            let message = await SonosMusicService.shared.play(
                references: references,
                collectionTitle: playlist.name
            )
            status = message.hasPrefix("Playing ") ? "playing" : message
            isWorking = false
            return message.hasPrefix("Playing ")
        } catch {
            status = error.localizedDescription
            isWorking = false
            return false
        }
    }

    private func exchangeAuthorizationCode(_ code: String) async {
        do {
            let token = try await tokenRequest([
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
                URLQueryItem(name: "client_id", value: Self.clientID),
                URLQueryItem(name: "code_verifier", value: pendingVerifier)
            ])
            try accept(token)
            try await loadProfileAndPlaylists()
        } catch {
            clearSession(message: error.localizedDescription)
        }
        pendingVerifier = ""
        pendingState = ""
        isWorking = false
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = SpotifyRefreshTokenStore.read() else {
            throw SpotifyAccountFailure.missingRefreshToken
        }
        let token = try await tokenRequest([
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.clientID)
        ])
        try accept(token, existingRefreshToken: refreshToken)
    }

    private func tokenRequest(_ fields: [URLQueryItem]) async throws -> SpotifyTokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SpotifyAccountFailure.invalidResponse
        }
        guard 200..<300 ~= response.statusCode else {
            throw SpotifyAccountFailure.httpStatus(response.statusCode)
        }
        return try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
    }

    private func accept(
        _ response: SpotifyTokenResponse,
        existingRefreshToken: String? = nil
    ) throws {
        let refreshToken = response.refreshToken ?? existingRefreshToken
        guard let refreshToken, !refreshToken.isEmpty else {
            throw SpotifyAccountFailure.missingRefreshToken
        }
        try SpotifyRefreshTokenStore.write(refreshToken)
        accessToken = response.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(max(60, response.expiresIn - 60)))
        isConnected = true
    }

    private func loadProfileAndPlaylists() async throws {
        async let profileResult: SpotifyProfileResponse = get(
            URL(string: "https://api.spotify.com/v1/me")!
        )
        async let playlistResult = fetchPlaylists()
        let (profile, fetchedPlaylists) = try await (profileResult, playlistResult)
        displayName = profile.displayName ?? profile.id
        playlists = fetchedPlaylists
        isConnected = true
        status = playlists.isEmpty ? "Spotify connected" : "\(playlists.count) Spotify playlists"
    }

    private func fetchPlaylists() async throws -> [SpotifyUserPlaylist] {
        var nextURL: URL? = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")
        var values: [SpotifyUserPlaylist] = []
        var seen = Set<String>()
        var pageCount = 0

        while let url = nextURL, pageCount < 20 {
            let page: SpotifyPlaylistPageResponse = try await get(url)
            for row in page.items where seen.insert(row.id).inserted {
                values.append(row.playlist)
            }
            nextURL = page.next
            pageCount += 1
        }
        // Keep Spotify's account/library ordering so recently added or moved
        // playlists remain ahead of older ones.
        return values
    }

    private func fetchTracks(in playlist: SpotifyUserPlaylist) async throws -> [SpotifyTrackReference] {
        var components = URLComponents(
            string: "https://api.spotify.com/v1/playlists/\(playlist.id)/items"
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "additional_types", value: "track")
        ]
        var nextURL: URL? = components.url
        var references: [SpotifyTrackReference] = []
        var seen = Set<String>()
        var pageCount = 0

        while let url = nextURL, pageCount < 20 {
            let page: SpotifyPlaylistItemsPageResponse = try await get(url)
            for row in page.items {
                guard let track = row.item ?? row.track,
                      track.type == nil || track.type == "track",
                      let id = track.id,
                      id.count == 22,
                      seen.insert(id).inserted else { continue }
                references.append(SpotifyTrackReference(
                    canonical: "spotify:track:\(id)",
                    encoded: "spotify%3atrack%3a\(id)"
                ))
            }
            nextURL = page.next
            pageCount += 1
        }
        guard !references.isEmpty else { throw SpotifyAccountFailure.emptyPlaylist }
        return references
    }

    private func get<Response: Decodable>(_ url: URL, retrying: Bool = true) async throws -> Response {
        if accessToken == nil || Date() >= accessTokenExpiry {
            try await refreshAccessToken()
        }
        guard let accessToken else { throw SpotifyAccountFailure.missingRefreshToken }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SpotifyAccountFailure.invalidResponse
        }
        if response.statusCode == 401, retrying {
            self.accessToken = nil
            try await refreshAccessToken()
            return try await get(url, retrying: false)
        }
        guard 200..<300 ~= response.statusCode else {
            throw SpotifyAccountFailure.httpStatus(response.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func clearSession(message: String) {
        accessToken = nil
        accessTokenExpiry = .distantPast
        isConnected = false
        displayName = ""
        playlists = []
        status = message
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension SpotifyAccountService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }
}

private enum SpotifyRefreshTokenStore {
    private static let service = "org.example.wall.wipewall.spotify"
    private static let account = "refresh-token"

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) throws {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SpotifyAccountFailure.invalidResponse }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct SpotifyProfileResponse: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct SpotifyPlaylistPageResponse: Decodable {
    let items: [SpotifyPlaylistResponse]
    let next: URL?
}

private struct SpotifyPlaylistResponse: Decodable {
    let id: String
    let name: String
    let uri: String
    let owner: SpotifyPlaylistOwnerResponse?
    let images: [SpotifyImageResponse]?
    let tracks: SpotifyPlaylistContentsResponse?
    let items: SpotifyPlaylistContentsResponse?

    var playlist: SpotifyUserPlaylist {
        SpotifyUserPlaylist(
            id: id,
            name: name,
            uri: uri,
            ownerName: owner?.displayName ?? "",
            artworkURL: images?.first?.url,
            trackCount: items?.total ?? tracks?.total ?? 0
        )
    }
}

private struct SpotifyPlaylistOwnerResponse: Decodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

private struct SpotifyImageResponse: Decodable {
    let url: URL
}

private struct SpotifyPlaylistContentsResponse: Decodable {
    let total: Int
}

private struct SpotifyPlaylistItemsPageResponse: Decodable {
    let items: [SpotifyPlaylistItemResponse]
    let next: URL?
}

private struct SpotifyPlaylistItemResponse: Decodable {
    let item: SpotifyTrackResponse?
    let track: SpotifyTrackResponse?
}

private struct SpotifyTrackResponse: Decodable {
    let id: String?
    let type: String?
}
