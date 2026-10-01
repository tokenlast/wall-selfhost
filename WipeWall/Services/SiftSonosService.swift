import AVFoundation
import Foundation
import Security

struct SiftCloudFile: Codable, Equatable {
    let sha256: String
    let bytes: Int?
    let relativePath: String
    let kind: String
    let mimeType: String?

    var isAudio: Bool {
        kind.caseInsensitiveCompare("audio") == .orderedSame
            || mimeType?.lowercased().hasPrefix("audio/") == true
    }

    var isArtwork: Bool {
        kind.caseInsensitiveCompare("artwork") == .orderedSame
            || mimeType?.lowercased().hasPrefix("image/") == true
            || ["jpg", "jpeg", "png", "webp", "gif"].contains(
                URL(fileURLWithPath: relativePath).pathExtension.lowercased()
            )
    }
}

struct SiftTrackMetadata: Codable, Equatable {
    let title: String?
    let artist: String?
    let album: String?
    let artworkUrl: String?
    let durationSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case title, artist, album, artworkUrl, durationSeconds, duration, nowPlaying
    }

    private struct NowPlayingMetadata: Decodable {
        let duration: Double?

        private enum CodingKeys: String, CodingKey { case duration, durationSeconds }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            duration = Self.flexibleDouble(in: container, forKey: .durationSeconds)
                ?? Self.flexibleDouble(in: container, forKey: .duration)
        }

        private static func flexibleDouble(
            in container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Double? {
            if let value = try? container.decode(Double.self, forKey: key) { return value }
            if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        artworkUrl = try container.decodeIfPresent(String.self, forKey: .artworkUrl)
        let nested = try container.decodeIfPresent(NowPlayingMetadata.self, forKey: .nowPlaying)
        durationSeconds = Self.flexibleDouble(in: container, forKey: .durationSeconds)
            ?? Self.flexibleDouble(in: container, forKey: .duration)
            ?? nested?.duration
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(artist, forKey: .artist)
        try container.encodeIfPresent(album, forKey: .album)
        try container.encodeIfPresent(artworkUrl, forKey: .artworkUrl)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    }

    private static func flexibleDouble(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }
}

struct SiftCloudTrack: Codable, Equatable {
    let id: String
    let primaryUrl: String?
    let sourceService: String?
    let metadata: SiftTrackMetadata?
    let files: [SiftCloudFile]
    let streamIds: [String]

    var audioFile: SiftCloudFile? { files.first(where: \.isAudio) }
    var artworkFile: SiftCloudFile? { files.first(where: \.isArtwork) }
    var title: String { metadata?.title?.siftNonempty ?? "Untitled" }
    var artist: String { metadata?.artist?.siftNonempty ?? "Unknown artist" }
    var album: String { metadata?.album?.siftNonempty ?? "" }
    var duration: TimeInterval { max(0, metadata?.durationSeconds ?? 0) }

    private enum CodingKeys: String, CodingKey {
        case id, primaryUrl, sourceService, metadata, files, streamIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        primaryUrl = try container.decodeIfPresent(String.self, forKey: .primaryUrl)
        sourceService = try container.decodeIfPresent(String.self, forKey: .sourceService)
        metadata = try container.decodeIfPresent(SiftTrackMetadata.self, forKey: .metadata)
        files = try container.decodeIfPresent([SiftCloudFile].self, forKey: .files) ?? []
        streamIds = try container.decodeIfPresent([String].self, forKey: .streamIds) ?? []
    }
}

struct SiftArtworkResolver {
    static func url(
        for track: SiftCloudTrack,
        baseURL: URL,
        accessToken: String?
    ) -> URL? {
        if let file = track.artworkFile,
           let accessToken = accessToken?.siftNonempty {
            let endpoint = baseURL
                .appendingPathComponent("v1/files")
                .appendingPathComponent(file.sha256)
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true)
            components?.queryItems = [
                URLQueryItem(name: "name", value: file.relativePath),
                URLQueryItem(name: "token", value: accessToken)
            ]
            if let url = components?.url { return url }
        }

        guard let rawURL = track.metadata?.artworkUrl?.siftNonempty,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }
}

struct SiftDeleteAfterListen: Codable, Equatable {
    let enabled: Bool
    let targets: [String]

    init(enabled: Bool = false, targets: [String] = []) {
        self.enabled = enabled
        self.targets = targets
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let enabled = try? single.decode(Bool.self) {
            self.init(enabled: enabled, targets: enabled ? ["playlist"] : [])
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let targets = try container.decodeIfPresent([String].self, forKey: .targets) ?? []
        self.init(enabled: enabled, targets: enabled && targets.isEmpty ? ["playlist"] : targets)
    }

    private enum CodingKeys: String, CodingKey { case enabled, targets }
}

struct SiftPlaylistSettings: Codable, Equatable {
    let deleteAfterListen: SiftDeleteAfterListen?
}

struct SiftCloudPlaylist: Codable, Equatable {
    let id: String
    let name: String
    let trackIds: [String]
    let settings: SiftPlaylistSettings?
}

struct SiftCloudLibrary: Codable, Equatable {
    let playlists: [SiftCloudPlaylist]
    let tracks: [SiftCloudTrack]
}

struct SiftCloudQueue: Equatable {
    let playlist: SiftCloudPlaylist
    let tracks: [SiftCloudTrack]
}

struct SiftDeparturePlan: Equatable {
    let playlistID: String
    let trackID: String
    let deleteTargets: [String]
}

struct SiftSonosPlaybackPolicy {
    static let advanceLeadTime: TimeInterval = 0.75

    static func reconciledElapsed(
        previous: TimeInterval,
        reported: TimeInterval,
        pollInterval: TimeInterval,
        wasPlaying: Bool
    ) -> TimeInterval {
        let safePrevious = max(0, previous)
        let locallyAdvanced = wasPlaying
            ? safePrevious + max(0, min(pollInterval, 2))
            : safePrevious
        return max(locallyAdvanced, max(0, reported))
    }

    static func shouldAdvance(
        elapsed: TimeInterval,
        duration: TimeInterval,
        state: SonosTransportState,
        observedPlaying: Bool
    ) -> Bool {
        if duration > 0,
           elapsed >= max(0, duration - advanceLeadTime) {
            return true
        }
        return observedPlaying && state == .stopped && elapsed >= 5
    }
}

private struct SiftLibraryEnvelope: Decodable { let library: SiftCloudLibrary }
private struct SiftLoginEnvelope: Decodable {
    let deviceToken: String
    let device: SiftDevice?
    struct SiftDevice: Decodable { let id: String? }
}
private struct SiftStreamEnvelope: Decodable { let streamPath: String; let expiresAt: String }

enum SiftSonosError: LocalizedError {
    case notConnected
    case invalidResponse
    case requestFailed(Int, String)
    case playlistNotFound(String)
    case noPlayableTracks(String)
    case speakerUnavailable
    case currentTrackUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Connect Sift in Wall settings first."
        case .invalidResponse: return "Sift returned an unreadable response."
        case let .requestFailed(status, message):
            return message.isEmpty ? "Sift returned HTTP \(status)." : message
        case let .playlistNotFound(name): return "I couldn’t find the Sift playlist \(name)."
        case let .noPlayableTracks(name): return "The Sift playlist \(name) has no ready audio files."
        case .speakerUnavailable: return "I couldn’t reach the Living Room Sonos."
        case .currentTrackUnavailable: return "I couldn’t identify the song currently playing."
        }
    }
}

@MainActor
final class SiftSonosService: ObservableObject {
    static let shared = SiftSonosService()

    @Published private(set) var isConnected: Bool
    @Published private(set) var accountName = ""
    @Published private(set) var status: String
    @Published private(set) var isWorking = false

    private let baseURL = WallConfiguration.siftURL
    private let session: URLSession
    private let defaults: UserDefaults
    private let keychain: SiftTokenStore
    private var playback: PlaybackSession?
    private var pollingTask: Task<Void, Never>?
    private var isAdvancing = false
    private var metadataLibraryCache: (library: SiftCloudLibrary, expiresAt: Date)?

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        keychain: SiftTokenStore = SiftTokenStore()
    ) {
        self.session = session
        self.defaults = defaults
        self.keychain = keychain
        let hasToken = keychain.read() != nil
        isConnected = hasToken
        accountName = hasToken ? "Your Sift" : ""
        status = hasToken ? "Private Sift ready" : "Private Sift credential missing from this build"
    }

    deinit { pollingTask?.cancel() }

    func connect(username rawUsername: String, password: String) async {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            status = "Enter your Sift username and password."
            return
        }
        isWorking = true
        status = "Connecting…"
        defer { isWorking = false }
        do {
            let deviceID = siftDeviceID()
            let payload: [String: Any] = [
                "username": username,
                "password": password,
                "device": ["id": deviceID, "name": "Wall iPad", "platform": "ios"]
            ]
            let envelope: SiftLoginEnvelope = try await request(
                "auth/login", method: "POST", payload: payload, authenticated: false
            )
            try keychain.write(envelope.deviceToken)
            defaults.set(envelope.device?.id ?? deviceID, forKey: "wall.sift.device-id")
            defaults.set(username, forKey: "wall.sift.account")
            _ = try await library()
            accountName = username
            isConnected = true
            status = "Connected to private Sift"
        } catch {
            keychain.delete()
            isConnected = false
            status = error.localizedDescription
        }
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        playback = nil
        keychain.delete()
        isConnected = false
        status = isConnected ? "Private Sift ready" : "Not connected"
    }

    func verifyConnection() async {
        guard authorizationToken != nil else {
            isConnected = false
            status = "Private Sift credential missing from this build"
            return
        }
        isWorking = true
        status = "Checking private Sift…"
        defer { isWorking = false }
        do {
            _ = try await library()
            isConnected = true
            accountName = "Your Sift"
            status = "Private Sift ready"
        } catch {
            isConnected = false
            status = error.localizedDescription
        }
    }

    func availablePlaylists() async throws -> [SiftCloudPlaylist] {
        try await library().playlists
    }

    func availableQueue() async throws -> SiftCloudQueue {
        let library = try await library()
        guard let playlist = Self.resolvePlaylist(named: "queue", in: library.playlists) else {
            throw SiftSonosError.playlistNotFound("Queue")
        }
        return SiftCloudQueue(
            playlist: playlist,
            tracks: Self.orderedTracks(in: playlist, library: library)
        )
    }

    func track(matchingSonosURI rawURI: String) async -> SiftCloudTrack? {
        let decoded = rawURI.removingPercentEncoding ?? rawURI
        guard let host = baseURL.host, decoded.localizedCaseInsensitiveContains(host) else { return nil }
        let library: SiftCloudLibrary
        if let cache = metadataLibraryCache, cache.expiresAt > Date() {
            library = cache.library
        } else {
            guard let fetched = try? await self.library() else { return nil }
            metadataLibraryCache = (fetched, Date().addingTimeInterval(60))
            library = fetched
        }
        return library.tracks.first { track in
            track.files.contains { file in
                decoded.contains(file.sha256)
                    || decoded.localizedCaseInsensitiveContains(file.relativePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? file.relativePath)
                    || decoded.localizedCaseInsensitiveContains(file.relativePath)
            }
        }
    }

    func artworkURL(for track: SiftCloudTrack) -> URL? {
        SiftArtworkResolver.url(
            for: track,
            baseURL: baseURL,
            accessToken: authorizationToken
        )
    }

    func play(
        playlist requestedName: String,
        shuffle: Bool,
        startingAtTrackID: String? = nil
    ) async -> String {
        do {
            let library = try await library()
            guard let playlist = Self.resolvePlaylist(named: requestedName, in: library.playlists) else {
                throw SiftSonosError.playlistNotFound(requestedName)
            }
            let byID = Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0) })
            var tracks = playlist.trackIds.compactMap { byID[$0] }.filter { $0.audioFile != nil }
            guard !tracks.isEmpty else { throw SiftSonosError.noPlayableTracks(playlist.name) }
            if shuffle { tracks.shuffle() }
            if let startingAtTrackID,
               let start = tracks.firstIndex(where: { $0.id == startingAtTrackID }) {
                tracks = Array(tracks[start...])
            }
            let coordinator = try await resolveLivingRoomCoordinator()
            playback = PlaybackSession(
                playlist: playlist,
                tracks: tracks,
                originalTracks: tracks,
                index: 0,
                coordinator: coordinator,
                isShuffled: shuffle,
                currentDuration: 0,
                lastElapsed: 0,
                observedPlaying: false,
                lastPollAt: Date(),
                lastTransportState: .unknown
            )
            try await playCurrentTrack()
            startPolling()
            return "Playing \(playlist.name) from Sift\(shuffle ? " on shuffle" : "") on Sonos."
        } catch {
            return "I couldn’t start Sift. \(error.localizedDescription)"
        }
    }

    func control(action: String) async -> String? {
        guard var playback else { return nil }
        do {
            switch action.lowercased() {
            case "next":
                try await advance(cleaningDepartingTrack: true)
                return "Skipped to the next Sift track."
            case "previous":
                playback.index = max(0, playback.index - 1)
                self.playback = playback
                try await playCurrentTrack()
                return "Went back one Sift track."
            case "play", "pause":
                let command = action.lowercased() == "play" ? "Play" : "Pause"
                _ = try await soap(
                    coordinator: playback.coordinator,
                    action: command,
                    body: "<InstanceID>0</InstanceID>\(command == "Play" ? "<Speed>1</Speed>" : "")"
                )
                return command == "Play" ? "Resumed Sift on Sonos." : "Paused Sift on Sonos."
            default:
                return nil
            }
        } catch {
            return "I couldn’t control Sift. \(error.localizedDescription)"
        }
    }

    var activeShuffleState: Bool? { playback?.isShuffled }

    func toggleShuffleIfActive() -> Bool? {
        guard var playback else { return nil }
        let enabling = !playback.isShuffled
        let played = Array(playback.tracks.prefix(playback.index + 1))
        let playedIDs = Set(played.map(\.id))
        var upcoming = playback.originalTracks.filter { !playedIDs.contains($0.id) }
        if enabling { upcoming.shuffle() }
        playback.tracks = played + upcoming
        playback.isShuffled = enabling
        self.playback = playback
        return enabling
    }

    func addCurrentTrack(to requestedPlaylist: String) async -> String {
        do {
            let library = try await library()
            guard let target = Self.resolvePlaylist(named: requestedPlaylist, in: library.playlists) else {
                throw SiftSonosError.playlistNotFound(requestedPlaylist)
            }
            if let current = playback?.tracks[safe: playback?.index ?? -1] {
                try await postOperation(type: "track.add", payload: [
                    "playlistId": target.id,
                    "track": try Self.jsonObject(for: current)
                ])
                return "Added \(current.title) to \(target.name) on Sift."
            }

            let coordinator = try await resolveLivingRoomCoordinator()
            let data = try await soap(
                coordinator: coordinator,
                action: "GetPositionInfo",
                body: "<InstanceID>0</InstanceID>"
            )
            let values = SonosMusicXML.flatValues(in: data)
            let metadata = SonosSOAP.parseTrackMetadata(from: data)
            let decodedURI = (values["TrackURI"] ?? "").removingPercentEncoding ?? (values["TrackURI"] ?? "")
            let reference: SpotifyTrackReference?
            if let embedded = SpotifyTrackResolver.reference(in: decodedURI) {
                reference = embedded
            } else {
                reference = try? await SpotifyTrackResolver().resolve(
                    query: "\(metadata.title) by \(metadata.artist)"
                )
            }
            guard let reference else { throw SiftSonosError.currentTrackUnavailable }
            let payload: [String: Any] = [
                "url": "https://open.spotify.com/track/\(reference.id)",
                "title": metadata.title,
                "artist": metadata.artist,
                "album": metadata.album,
                "playlistId": target.id,
                "respondAsync": true
            ]
            let _: [String: SiftJSONValue] = try await request(
                "v1/intake/link", method: "POST", payload: payload, accepted: 200...202
            )
            let label = metadata.title.siftNonempty ?? "the current song"
            return "Added \(label) to \(target.name) on Sift."
        } catch {
            return "I couldn’t add that song to Sift. \(error.localizedDescription)"
        }
    }

    nonisolated static func resolvePlaylist(named requestedName: String, in playlists: [SiftCloudPlaylist]) -> SiftCloudPlaylist? {
        let requested = normalizedName(requestedName)
        if ["queue", "myqueue", "siftqueue"].contains(requested) {
            return playlists.first { normalizedName($0.id) == "queue" || normalizedName($0.name) == "queue" }
        }
        if let exact = playlists.first(where: {
            normalizedName($0.name) == requested || normalizedName($0.id) == requested
        }) { return exact }
        let contained = playlists.filter {
            normalizedName($0.name).contains(requested) || requested.contains(normalizedName($0.name))
        }
        return contained.count == 1 ? contained[0] : nil
    }

    nonisolated static func orderedTracks(
        in playlist: SiftCloudPlaylist,
        library: SiftCloudLibrary
    ) -> [SiftCloudTrack] {
        let byID = Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0) })
        return playlist.trackIds.compactMap { byID[$0] }
    }

    nonisolated static func departurePlan(
        playlist: SiftCloudPlaylist,
        trackID: String,
        listenedSeconds: TimeInterval
    ) -> SiftDeparturePlan? {
        guard listenedSeconds >= 5,
              let cleanup = playlist.settings?.deleteAfterListen,
              cleanup.enabled else { return nil }
        return SiftDeparturePlan(
            playlistID: playlist.id,
            trackID: trackID,
            deleteTargets: cleanup.targets.isEmpty ? ["playlist"] : cleanup.targets
        )
    }

    nonisolated private static func normalizedName(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private func library() async throws -> SiftCloudLibrary {
        let envelope: SiftLibraryEnvelope = try await request("v1/library")
        return envelope.library
    }

    private func playCurrentTrack() async throws {
        guard var playback,
              let track = playback.tracks[safe: playback.index],
              let file = track.audioFile else { throw SiftSonosError.currentTrackUnavailable }
        let ticket: SiftStreamEnvelope = try await request(
            "v1/sonos/stream",
            method: "POST",
            payload: ["sha256": file.sha256, "name": file.relativePath],
            accepted: 200...201
        )
        guard let streamURL = URL(string: ticket.streamPath, relativeTo: baseURL)?.absoluteURL else {
            throw SiftSonosError.invalidResponse
        }
        let duration = track.duration > 0 ? track.duration : await probeDuration(of: streamURL)
        let transportURI = "x-rincon-mp3radio://\(streamURL.absoluteString)"
        let metadata = SonosMusicXML.streamDIDL(
            title: track.title,
            artist: track.artist,
            album: track.album
        )
        _ = try await soap(
            coordinator: playback.coordinator,
            action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID><CurrentURI>\(SonosMusicXML.escape(transportURI))</CurrentURI><CurrentURIMetaData>\(SonosMusicXML.escape(metadata))</CurrentURIMetaData>"
        )
        _ = try await soap(
            coordinator: playback.coordinator,
            action: "Play",
            body: "<InstanceID>0</InstanceID><Speed>1</Speed>"
        )
        playback.currentDuration = duration
        playback.lastElapsed = 0
        playback.observedPlaying = false
        playback.lastPollAt = Date()
        playback.lastTransportState = .unknown
        self.playback = playback
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPlayback()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func pollPlayback() async {
        guard !isAdvancing, var playback,
              let track = playback.tracks[safe: playback.index] else { return }
        let coordinator = playback.coordinator
        do {
            async let positionData = soap(
                coordinator: coordinator,
                action: "GetPositionInfo",
                body: "<InstanceID>0</InstanceID>"
            )
            async let transportData = soap(
                coordinator: coordinator,
                action: "GetTransportInfo",
                body: "<InstanceID>0</InstanceID>"
            )
            let (position, transport) = try await (positionData, transportData)
            let positionValues = SonosMusicXML.flatValues(in: position)
            let state = SonosTransportState(soapValue: SonosMusicXML.flatValues(in: transport)["CurrentTransportState"])
            let reportedElapsed = Self.seconds(fromSonosTime: positionValues["RelTime"])
            let reportedDuration = Self.seconds(fromSonosTime: positionValues["TrackDuration"])
            if reportedDuration > 0 { playback.currentDuration = reportedDuration }
            let duration = playback.currentDuration > 0 ? playback.currentDuration : track.duration
            let now = Date()
            let elapsed = SiftSonosPlaybackPolicy.reconciledElapsed(
                previous: playback.lastElapsed,
                reported: reportedElapsed,
                pollInterval: now.timeIntervalSince(playback.lastPollAt),
                wasPlaying: playback.lastTransportState.isPlaying
            )
            playback.lastElapsed = elapsed
            playback.observedPlaying = playback.observedPlaying || state.isPlaying
            playback.lastPollAt = now
            playback.lastTransportState = state
            self.playback = playback
            if SiftSonosPlaybackPolicy.shouldAdvance(
                elapsed: elapsed,
                duration: duration,
                state: state,
                observedPlaying: playback.observedPlaying
            ) {
                try await advance(cleaningDepartingTrack: true)
            }
        } catch {
            // A transient local-network miss should not tear down a long playlist.
        }
    }

    private func advance(cleaningDepartingTrack: Bool) async throws {
        guard !isAdvancing, var playback else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        if cleaningDepartingTrack { try await cleanDepartingTrackIfNeeded(playback) }
        let next = playback.index + 1
        guard next < playback.tracks.count else {
            _ = try? await soap(
                coordinator: playback.coordinator,
                action: "Stop",
                body: "<InstanceID>0</InstanceID>"
            )
            pollingTask?.cancel()
            pollingTask = nil
            self.playback = nil
            return
        }
        playback.index = next
        self.playback = playback
        try await playCurrentTrack()
    }

    private func cleanDepartingTrackIfNeeded(_ playback: PlaybackSession) async throws {
        guard let track = playback.tracks[safe: playback.index],
              let plan = Self.departurePlan(
                playlist: playback.playlist,
                trackID: track.id,
                listenedSeconds: playback.lastElapsed
              ) else { return }
        try await postOperation(type: "track.remove", payload: [
            "playlistId": plan.playlistID,
            "trackId": plan.trackID,
            "reason": "listened_once",
            "listenedAt": ISO8601DateFormatter().string(from: Date()),
            "deleteTargets": plan.deleteTargets
        ])
    }

    private func probeDuration(of streamURL: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: streamURL)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func postOperation(type: String, payload: [String: Any]) async throws {
        let operation: [String: Any] = [
            "id": "wall_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))",
            "type": type,
            "deviceId": siftDeviceID(),
            "payload": payload
        ]
        let _: [String: SiftJSONValue] = try await request(
            "v1/ops", method: "POST", payload: operation, accepted: 200...201
        )
    }

    private func resolveLivingRoomCoordinator() async throws -> SonosCoordinator {
        var hosts = [defaults.string(forKey: "wall.sonos.host")].compactMap { $0 }
        hosts = Array(NSOrderedSet(array: hosts)) as? [String] ?? hosts
        for host in hosts {
            guard let baseURL = URL(string: "http://\(host):1400") else { continue }
            if let data = try? await SonosSOAP.validatedData(
                for: SonosSOAP.makeRequest(
                    baseURL: baseURL,
                    path: "ZoneGroupTopology/Control",
                    service: "urn:schemas-upnp-org:service:ZoneGroupTopology:1",
                    action: "GetZoneGroupState",
                    body: ""
                ),
                using: session
            ), let topology = SonosMusicXML.flatValues(in: data)["ZoneGroupState"],
               let coordinator = SonosMusicXML.coordinator(in: topology, roomName: "Living Room") {
                defaults.set(coordinator.host, forKey: "wall.sonos.host")
                return coordinator
            }
        }
        throw SiftSonosError.speakerUnavailable
    }

    private func soap(coordinator: SonosCoordinator, action: String, body: String) async throws -> Data {
        let request = SonosSOAP.makeRequest(
            baseURL: coordinator.baseURL,
            path: SonosSOAP.avTransportPath,
            service: SonosSOAP.avTransportService,
            action: action,
            body: body,
            timeout: 7
        )
        return try await SonosSOAP.validatedData(for: request, using: session)
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        payload: [String: Any]? = nil,
        authenticated: Bool = true,
        accepted: ClosedRange<Int> = 200...299
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 25
        if authenticated {
            guard let token = authorizationToken else { throw SiftSonosError.notConnected }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SiftSonosError.invalidResponse }
        guard accepted.contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = object?["error"] as? String ?? object?["message"] as? String ?? ""
            throw SiftSonosError.requestFailed(response.statusCode, message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SiftSonosError.invalidResponse }
    }

    private func siftDeviceID() -> String {
        if let saved = defaults.string(forKey: "wall.sift.device-id"), !saved.isEmpty { return saved }
        let value = "wall-ipad-\(UUID().uuidString.lowercased())"
        defaults.set(value, forKey: "wall.sift.device-id")
        return value
    }

    private var authorizationToken: String? {
        keychain.read()
    }


    private static func seconds(fromSonosTime value: String?) -> TimeInterval {
        let parts = (value ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private static func jsonObject<T: Encodable>(for value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private struct PlaybackSession {
        let playlist: SiftCloudPlaylist
        var tracks: [SiftCloudTrack]
        let originalTracks: [SiftCloudTrack]
        var index: Int
        let coordinator: SonosCoordinator
        var isShuffled: Bool
        var currentDuration: TimeInterval
        var lastElapsed: TimeInterval
        var observedPlaying: Bool
        var lastPollAt: Date
        var lastTransportState: SonosTransportState
    }
}

struct SiftTokenStore {
    private let service = "org.example.wall.wall.sift"
    private let account = "device-token"

    func read() -> String? {
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

    func write(_ token: String) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SiftSonosError.invalidResponse }
    }

    func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

private enum SiftJSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: SiftJSONValue]), array([SiftJSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: SiftJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([SiftJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private extension String {
    var siftNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
