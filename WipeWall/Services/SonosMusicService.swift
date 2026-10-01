import Foundation

struct SpotifyTrackReference: Equatable {
    let canonical: String
    let encoded: String

    var id: String { String(canonical.dropFirst("spotify:track:".count)) }
}

enum SpotifyTrackResolverFailure: LocalizedError {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case noExactTrack

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Wall could not prepare the music search."
        case .invalidResponse: return "Wall received an unreadable music-search response."
        case let .httpStatus(status): return "Wall’s music search is unavailable (HTTP \(status))."
        case .noExactTrack: return "Wall could not find an exact Spotify track for that request."
        }
    }
}

protocol SpotifyTrackResolving {
    func resolve(query: String) async throws -> SpotifyTrackReference
}

/// Resolves voice requests against the device-authenticated Spotify catalog broker.
/// Selected cards bypass this lookup and keep their exact Spotify reference.
final class SpotifyTrackResolver: SpotifyTrackResolving {
    private let search: (String) async throws -> [WallMusicSearchResult]

    init(search: @escaping (String) async throws -> [WallMusicSearchResult] = {
        try await SpotifyCatalogClient.shared.searchTracks(query: $0)
    }) {
        self.search = search
    }

    func resolve(query: String) async throws -> SpotifyTrackReference {
        if let reference = Self.reference(in: query) { return reference }
        let intent = SpotifyTrackQuery(query)
        guard !intent.title.isEmpty else { throw SpotifyTrackResolverFailure.invalidRequest }
        let catalogQuery = [intent.title, intent.artist].compactMap { $0 }.joined(separator: " ")
        let candidates = try await search(catalogQuery)
        for candidate in candidates {
            let metadata = SpotifyTrackPageMetadata(title: candidate.trackName, artist: candidate.artistName)
            let titleAndArtist = SpotifyTrackPageMetadata.normalized(candidate.spotifyQuery.replacingOccurrences(of: " by ", with: " "))
            // Speech sometimes omits "by". Require the whole title+artist,
            // not a partial title or a weak first-result match.
            if metadata.matches(query: query) || (intent.artist == nil
                && SpotifyTrackPageMetadata.normalized(intent.title) == titleAndArtist) {
                return candidate.reference
            }
        }
        throw SpotifyTrackResolverFailure.noExactTrack
    }

    static func reference(inResponseData data: Data) -> SpotifyTrackReference? {
        references(inResponseData: data).first
    }

    static func references(inResponseData data: Data) -> [SpotifyTrackReference] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var seen = Set<String>()
        return allStrings(in: json)
            .flatMap(references(in:))
            .filter { seen.insert($0.canonical).inserted }
    }

    static func reference(in text: String) -> SpotifyTrackReference? {
        references(in: text).first
    }

    static func references(in text: String) -> [SpotifyTrackReference] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = canonicalExpression.matches(in: text, range: range)
            + trackURLExpression.matches(in: text, range: range)
        var seen = Set<String>()
        return matches.compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let matched = String(text[swiftRange])
            guard let id = trackIDExpression.firstMatch(
                in: matched,
                range: NSRange(matched.startIndex..<matched.endIndex, in: matched)
            ).flatMap({ Range($0.range, in: matched) }).map({ String(matched[$0]) }) else {
                return nil
            }
            let canonical = "spotify:track:\(id)"
            guard seen.insert(canonical).inserted else { return nil }
            return SpotifyTrackReference(
                canonical: canonical,
                encoded: canonical.replacingOccurrences(of: ":", with: "%3a")
            )
        }
    }

    private static func allStrings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(allStrings) }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().flatMap { allStrings(in: dictionary[$0] as Any) }
        }
        return []
    }

    private static let canonicalExpression = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])spotify:track:[A-Za-z0-9]{22}(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )

    private static let trackURLExpression = try! NSRegularExpression(
        pattern: #"https?://open\.spotify\.com/(?:intl-[a-z]{2}/)?track/[A-Za-z0-9]{22}(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )

    private static let trackIDExpression = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9]{22}(?![A-Za-z0-9])"#
    )
}

struct SpotifyOEmbedMetadata: Decodable, Equatable {
    let title: String
    let providerName: String
    let iframeURL: String?
    let html: String

    private enum CodingKeys: String, CodingKey {
        case title
        case providerName = "provider_name"
        case iframeURL = "iframe_url"
        case html
    }

    func matches(reference: SpotifyTrackReference, query: String) -> Bool {
        let linkEvidence = [iframeURL ?? "", html].joined(separator: " ")
        guard providerName.caseInsensitiveCompare("Spotify") == .orderedSame,
              linkEvidence.localizedCaseInsensitiveContains("/embed/track/\(reference.id)") else {
            return false
        }
        let requestedTitle = SpotifyTrackQuery(query).title
        return SpotifyTrackPageMetadata.normalized(title)
            == SpotifyTrackPageMetadata.normalized(requestedTitle)
    }
}

struct SpotifyTrackPageMetadata: Equatable {
    let title: String
    let artist: String

    init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }

    init?(data: Data) {
        guard let html = String(data: data, encoding: .utf8),
              let title = Self.metaContent("og:title", in: html),
              let description = Self.metaContent("og:description", in: html) else { return nil }
        let artist = description.components(separatedBy: "·").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        self.title = Self.decodeEntities(title)
        self.artist = Self.decodeEntities(artist)
    }

    func matches(query: String) -> Bool {
        let intent = SpotifyTrackQuery(query)
        let actualTitle = Self.normalized(title)
        let expectedTitle = Self.normalized(intent.title)
        guard !expectedTitle.isEmpty, actualTitle == expectedTitle else {
            return false
        }
        guard let requestedArtist = intent.artist else { return true }
        let actualArtist = Self.normalized(artist)
        let expectedArtist = Self.normalized(requestedArtist)
        return !expectedArtist.isEmpty
            && (actualArtist == expectedArtist
                || actualArtist.contains(expectedArtist)
                || expectedArtist.contains(actualArtist))
    }

    private static func metaContent(_ property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            #"<meta[^>]*property=[\"']\#(escaped)[\"'][^>]*content=[\"']([^\"']*)[\"'][^>]*>"#,
            #"<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*property=[\"']\#(escaped)[\"'][^>]*>"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = expression.firstMatch(in: html, range: range),
               let contentRange = Range(match.range(at: 1), in: html) {
                return String(html[contentRange])
            }
        }
        return nil
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

struct SpotifyTrackQuery {
    let title: String
    let artist: String?

    init(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["start playing ", "play ", "put on "] where value.lowercased().hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        if let range = value.range(of: " by ", options: [.caseInsensitive, .backwards]) {
            title = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            artist = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = value
            artist = nil
        }
    }
}

enum SonosMusicFailure: LocalizedError {
    case speakerUnavailable
    case invalidResponse
    case queueRejected
    case playbackNotVerified

    var errorDescription: String? {
        switch self {
        case .speakerUnavailable: return "Living Room Sonos is not available on this Wi-Fi."
        case .invalidResponse: return "Sonos returned an unreadable response."
        case .queueRejected: return "Sonos could not add that Spotify track."
        case .playbackNotVerified:
            return "Sonos accepted the command, but Wall could not verify the requested track."
        }
    }
}

enum SonosQueueContinuationPolicy {
    static let enqueueAsNext = 1
    static let appendToEnd = 0
    static let playMode = "REPEAT_ALL"
    static let replacementPlayMode = "NORMAL"
}

struct SpotifySonosPlaybackIdentity: Equatable {
    let serviceID: Int
    let accountSerial: Int

    static func parse(_ values: [String]) -> SpotifySonosPlaybackIdentity? {
        for value in values {
            let decoded = value.replacingOccurrences(of: "&amp;", with: "&")
            guard let sid = queryInteger(named: "sid", in: decoded),
                  let serial = queryInteger(named: "sn", in: decoded),
                  sid > 0, serial >= 0 else { continue }
            return SpotifySonosPlaybackIdentity(serviceID: sid, accountSerial: serial)
        }
        return nil
    }

    private static func queryInteger(named name: String, in value: String) -> Int? {
        let pattern = "(?:[?&])\(NSRegularExpression.escapedPattern(for: name))=([0-9]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return Int(value[range])
    }
}

struct SpotifySongRadioContext: Equatable {
    let uri: String
    let metadata: String

    static func make(
        reference: SpotifyTrackReference,
        identity: SpotifySonosPlaybackIdentity
    ) -> SpotifySongRadioContext {
        let encodedObject = "spotify%3atrackRadio%3a\(reference.id)"
        let serviceNumber = identity.serviceID * 256 + 7
        let description = "SA_RINCON\(serviceNumber)_X_#Svc\(serviceNumber)-0-Token"
        let metadata = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"><item id=\"100c206c\(encodedObject)\" parentID=\"-1\" restricted=\"true\"><dc:title>Song Radio</dc:title><upnp:class>object.item.audioItem.audioBroadcast.#trackRadio</upnp:class><desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">\(description)</desc></item></DIDL-Lite>"
        return SpotifySongRadioContext(
            uri: "x-sonosapi-radio:\(encodedObject)?sid=\(identity.serviceID)&flags=8300&sn=\(identity.accountSerial)",
            metadata: metadata
        )
    }
}

/// Serializes queue mutations so two voice requests cannot interleave.
actor SonosMusicService {
    static let shared = SonosMusicService()

    private let resolver: SpotifyTrackResolving
    private let session: URLSession
    private let defaults: UserDefaults

    init(
        resolver: SpotifyTrackResolving = SpotifyTrackResolver(),
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.resolver = resolver
        self.session = session
        self.defaults = defaults
    }

    func play(query rawQuery: String) async -> String {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Tell me which song to play." }
        do {
            let reference = try await resolver.resolve(query: query)
            return await play(reference: reference, title: query)
        } catch {
            return "I couldn’t play that on Sonos. \(error.localizedDescription)"
        }
    }

    func play(reference: SpotifyTrackReference, title: String) async -> String {
        do {
            let coordinator = try await resolveLivingRoomCoordinator()
            try await clearQueue(coordinator: coordinator)
            let queuePosition = try await enqueue(
                reference,
                asNext: SonosQueueContinuationPolicy.appendToEnd,
                coordinator: coordinator
            )
            try await bindAndPlay(
                queuePosition: queuePosition,
                playMode: SonosQueueContinuationPolicy.replacementPlayMode,
                coordinator: coordinator
            )
            try await verify(
                reference,
                query: title,
                queuePosition: queuePosition,
                coordinator: coordinator
            )
            return "Playing \(title) on the Living Room Sonos."
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "Sonos could not complete that request."
            return "I couldn’t play that on Sonos. \(message)"
        }
    }

    /// Starts Spotify's actual Song Radio context for the selected seed track.
    /// Explicit queue actions remain additive and use the ordinary Sonos queue.
    func playRadio(
        seed: SpotifyTrackReference,
        title: String
    ) async -> String {
        do {
            let coordinator = try await resolveLivingRoomCoordinator()
            let identity = await spotifyPlaybackIdentity(coordinator: coordinator)
            let context = SpotifySongRadioContext.make(reference: seed, identity: identity)
            _ = try await soap(
                baseURL: coordinator.baseURL,
                path: SonosSOAP.avTransportPath,
                service: SonosSOAP.avTransportService,
                action: "SetAVTransportURI",
                body: "<InstanceID>0</InstanceID><CurrentURI>\(SonosMusicXML.escape(context.uri))</CurrentURI><CurrentURIMetaData>\(SonosMusicXML.escape(context.metadata))</CurrentURIMetaData>"
            )
            _ = try await soap(
                baseURL: coordinator.baseURL,
                path: SonosSOAP.avTransportPath,
                service: SonosSOAP.avTransportService,
                action: "Play",
                body: "<InstanceID>0</InstanceID><Speed>1</Speed>"
            )
            try await verifyRadio(seed: seed, coordinator: coordinator)
            return "Playing Spotify Radio for \(title) on the Living Room Sonos."
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "Sonos could not complete that request."
            return "I couldn’t play that on Sonos. \(message)"
        }
    }

    private func spotifyPlaybackIdentity(
        coordinator: SonosCoordinator
    ) async -> SpotifySonosPlaybackIdentity {
        if let data = try? await soap(
            baseURL: coordinator.baseURL,
            path: SonosSOAP.avTransportPath,
            service: SonosSOAP.avTransportService,
            action: "GetPositionInfo",
            body: "<InstanceID>0</InstanceID>"
        ) {
            let values = SonosMusicXML.flatValues(in: data)
            if let identity = SpotifySonosPlaybackIdentity.parse([
                values["TrackURI"] ?? "", values["TrackMetaData"] ?? ""
            ]) {
                defaults.set(identity.serviceID, forKey: "wall.sonos.spotify.sid")
                defaults.set(identity.accountSerial, forKey: "wall.sonos.spotify.sn")
                return identity
            }
        }
        let savedSID = defaults.integer(forKey: "wall.sonos.spotify.sid")
        if savedSID > 0 {
            return SpotifySonosPlaybackIdentity(
                serviceID: savedSID,
                accountSerial: defaults.integer(forKey: "wall.sonos.spotify.sn")
            )
        }
        // Recipient-specific fallback; observed playback identity takes priority.
        return SpotifySonosPlaybackIdentity(
            serviceID: Bundle.main.object(forInfoDictionaryKey: "WallSonosSpotifyServiceID") as? Int ?? 12,
            accountSerial: Bundle.main.object(forInfoDictionaryKey: "WallSonosSpotifyAccountSerial") as? Int ?? 0
        )
    }

    private func verifyRadio(seed: SpotifyTrackReference, coordinator: SonosCoordinator) async throws {
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 400_000_000)
            async let media = try? soap(
                baseURL: coordinator.baseURL,
                path: SonosSOAP.avTransportPath,
                service: SonosSOAP.avTransportService,
                action: "GetMediaInfo",
                body: "<InstanceID>0</InstanceID>"
            )
            async let transport = try? soap(
                baseURL: coordinator.baseURL,
                path: SonosSOAP.avTransportPath,
                service: SonosSOAP.avTransportService,
                action: "GetTransportInfo",
                body: "<InstanceID>0</InstanceID>"
            )
            let (mediaData, transportData) = await (media, transport)
            let raw = mediaData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let state = transportData.flatMap { SonosMusicXML.flatValues(in: $0)["CurrentTransportState"] }
            if raw.localizedCaseInsensitiveContains("trackRadio"),
               raw.localizedCaseInsensitiveContains(seed.id), state == "PLAYING" { return }
        }
        throw SonosMusicFailure.playbackNotVerified
    }

    /// Inserts an exact Spotify match next in the existing Sonos queue without
    /// seeking, changing transport state, or interrupting the current track.
    func queue(query rawQuery: String) async -> String {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Tell me which song to queue." }
        do {
            let reference = try await resolver.resolve(query: query)
            return await queue(reference: reference, title: query)
        } catch {
            return "I couldn’t queue that on Sonos. \(error.localizedDescription)"
        }
    }

    func queue(reference: SpotifyTrackReference, title: String) async -> String {
        do {
            let coordinator = try await resolveLivingRoomCoordinator()
            _ = try await enqueue(
                reference,
                asNext: SonosQueueContinuationPolicy.enqueueAsNext,
                coordinator: coordinator
            )
            return "Queued \(title) on the Living Room Sonos."
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "Sonos could not complete that request."
            return "I couldn’t queue that on Sonos. \(message)"
        }
    }

    /// Enqueues an authenticated Spotify playlist in its original order and
    /// starts at its first track. References come directly from Spotify's Web
    /// API, so no title-based resolver can substitute a similarly named song.
    func play(
        references: [SpotifyTrackReference],
        collectionTitle: String
    ) async -> String {
        guard !references.isEmpty else {
            return "I couldn’t play that on Sonos. That Spotify playlist is empty."
        }
        do {
            let coordinator = try await resolveLivingRoomCoordinator()
            try await clearQueue(coordinator: coordinator)
            var firstPosition: Int?
            for reference in references {
                let position = try await enqueue(
                    reference,
                    asNext: SonosQueueContinuationPolicy.appendToEnd,
                    coordinator: coordinator
                )
                firstPosition = firstPosition ?? position
            }
            guard let firstPosition else { throw SonosMusicFailure.queueRejected }
            try await bindAndPlay(
                queuePosition: firstPosition,
                playMode: SonosQueueContinuationPolicy.replacementPlayMode,
                coordinator: coordinator
            )
            return "Playing \(collectionTitle) from Spotify on the Living Room Sonos."
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "Sonos could not complete that request."
            return "I couldn’t play that on Sonos. \(message)"
        }
    }

    private func resolveLivingRoomCoordinator() async throws -> SonosCoordinator {
        var hosts: [String] = []
        if let saved = defaults.string(forKey: "wall.sonos.host"), !saved.isEmpty {
            hosts.append(saved)
        }
        // Use only the configured/discovered speaker; no home-network fallback.
        var visited = Set<String>()

        for host in hosts where visited.insert(host).inserted {
            guard let baseURL = URL(string: "http://\(host):1400") else { continue }
            do {
                let data = try await soap(
                    baseURL: baseURL,
                    path: "ZoneGroupTopology/Control",
                    service: "urn:schemas-upnp-org:service:ZoneGroupTopology:1",
                    action: "GetZoneGroupState",
                    body: ""
                )
                if let topology = SonosMusicXML.flatValues(in: data)["ZoneGroupState"],
                   let coordinator = SonosMusicXML.coordinator(in: topology, roomName: "Living Room") {
                    defaults.set(coordinator.host, forKey: "wall.sonos.host")
                    defaults.set("Living Room", forKey: "wall.sonos.room")
                    return coordinator
                }
            } catch {
                continue
            }
        }
        throw SonosMusicFailure.speakerUnavailable
    }

    private func enqueue(
        _ reference: SpotifyTrackReference,
        asNext: Int,
        coordinator: SonosCoordinator
    ) async throws -> Int {
        // This firmware accepts `sid=<SMAPI service>&sn=0` but can silently
        // resolve that form to an unrelated cached Spotify item. Prefer the
        // account-neutral ShareLink forms; exact post-play verification below
        // still rejects any mismatch.
        let candidates: [(service: Int, uri: String)] = [2311, 3079].flatMap { service in
            [
                (service, "x-sonos-spotify:\(reference.encoded)"),
                (service, reference.encoded)
            ]
        }
        for candidate in candidates {
            let metadata = SonosMusicXML.spotifyDIDL(
                reference: reference,
                serviceNumber: candidate.service
            )
            let body = """
            <InstanceID>0</InstanceID>
            <EnqueuedURI>\(SonosMusicXML.escape(candidate.uri))</EnqueuedURI>
            <EnqueuedURIMetaData>\(SonosMusicXML.escape(metadata))</EnqueuedURIMetaData>
            <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued>
            <EnqueueAsNext>\(asNext)</EnqueueAsNext>
            """
            do {
                let data = try await soap(
                    baseURL: coordinator.baseURL,
                    path: SonosSOAP.avTransportPath,
                    service: SonosSOAP.avTransportService,
                    action: "AddURIToQueue",
                    body: body
                )
                guard let value = SonosMusicXML.flatValues(in: data)["FirstTrackNumberEnqueued"],
                      let position = Int(value), position > 0 else {
                    throw SonosMusicFailure.invalidResponse
                }
                return position
            } catch SonosRequestError.httpStatus(500) {
                continue
            } catch {
                throw error
            }
        }
        throw SonosMusicFailure.queueRejected
    }

    private func clearQueue(coordinator: SonosCoordinator) async throws {
        _ = try await soap(
            baseURL: coordinator.baseURL,
            path: SonosSOAP.avTransportPath,
            service: SonosSOAP.avTransportService,
            action: "RemoveAllTracksFromQueue",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    private func bindAndPlay(
        queuePosition: Int,
        playMode: String,
        coordinator: SonosCoordinator
    ) async throws {
        let uuid = SonosMusicXML.normalizedUUID(coordinator.uuid)
        _ = try await soap(
            baseURL: coordinator.baseURL,
            path: SonosSOAP.avTransportPath,
            service: SonosSOAP.avTransportService,
            action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon-queue:\(uuid)#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
        )
        do {
            _ = try await seek(queuePosition: queuePosition, coordinator: coordinator)
        } catch SonosRequestError.httpStatus(500) {
            try await Task.sleep(nanoseconds: 180_000_000)
            _ = try await seek(queuePosition: queuePosition, coordinator: coordinator)
        }
        _ = try? await soap(
            baseURL: coordinator.baseURL,
            path: SonosSOAP.avTransportPath,
            service: SonosSOAP.avTransportService,
            action: "SetPlayMode",
            body: "<InstanceID>0</InstanceID><NewPlayMode>\(playMode)</NewPlayMode>"
        )
        _ = try await soap(
            baseURL: coordinator.baseURL,
            path: SonosSOAP.avTransportPath,
            service: SonosSOAP.avTransportService,
            action: "Play",
            body: "<InstanceID>0</InstanceID><Speed>1</Speed>"
        )
    }

    private func seek(queuePosition: Int, coordinator: SonosCoordinator) async throws -> Data {
        try await soap(
            baseURL: coordinator.baseURL,
            path: SonosSOAP.avTransportPath,
            service: SonosSOAP.avTransportService,
            action: "Seek",
            body: "<InstanceID>0</InstanceID><Unit>TRACK_NR</Unit><Target>\(queuePosition)</Target>"
        )
    }

    private func verify(
        _ reference: SpotifyTrackReference,
        query: String,
        queuePosition: Int,
        coordinator: SonosCoordinator
    ) async throws {
        // Older Sonos players can take several seconds to hydrate Spotify
        // metadata after AddURIToQueue. Verify the canonical ID when it is
        // exposed; otherwise accept the exact queue position plus PLAYING.
        for _ in 0..<14 {
            try await Task.sleep(nanoseconds: 450_000_000)
            if let data = try? await soap(
                baseURL: coordinator.baseURL,
                path: SonosSOAP.avTransportPath,
                service: SonosSOAP.avTransportService,
                action: "GetPositionInfo",
                body: "<InstanceID>0</InstanceID>"
            ) {
                let raw = String(data: data, encoding: .utf8) ?? ""
                let values = SonosMusicXML.flatValues(in: data)
                let nowPlaying = SonosSOAP.parseTrackMetadata(from: data)
                let matchesMetadata = Int(values["Track"] ?? "") == queuePosition
                    && !nowPlaying.title.isEmpty && !nowPlaying.artist.isEmpty
                    && SpotifyTrackPageMetadata(
                        title: nowPlaying.title,
                        artist: nowPlaying.artist
                    ).matches(query: query)
                if raw.localizedCaseInsensitiveContains(reference.id) || matchesMetadata,
                   let transport = try? await soap(
                        baseURL: coordinator.baseURL,
                        path: SonosSOAP.avTransportPath,
                        service: SonosSOAP.avTransportService,
                        action: "GetTransportInfo",
                        body: "<InstanceID>0</InstanceID>"
                   ), SonosMusicXML.flatValues(in: transport)["CurrentTransportState"] == "PLAYING" {
                    return
                }
            }
        }
        throw SonosMusicFailure.playbackNotVerified
    }

    private func soap(
        baseURL: URL,
        path: String,
        service: String,
        action: String,
        body: String
    ) async throws -> Data {
        let request = SonosSOAP.makeRequest(
            baseURL: baseURL,
            path: path,
            service: service,
            action: action,
            body: body,
            timeout: 7
        )
        return try await SonosSOAP.validatedData(for: request, using: session)
    }
}

struct SonosCoordinator: Equatable {
    let host: String
    let port: Int
    let uuid: String

    var baseURL: URL { URL(string: "http://\(host):\(port)")! }
}

enum SonosMusicXML {
    static func flatValues(in data: Data) -> [String: String] {
        SonosMusicFlatXMLParser(data: data).values
    }

    static func coordinator(in topologyXML: String, roomName: String) -> SonosCoordinator? {
        guard let data = topologyXML.data(using: .utf8) else { return nil }
        return SonosMusicTopologyParser(data: data).coordinator(roomName: roomName)
    }

    static func spotifyDIDL(reference: SpotifyTrackReference, serviceNumber: Int) -> String {
        let description = "SA_RINCON\(serviceNumber)_X_#Svc\(serviceNumber)-0-Token"
        return "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"><item id=\"00032020\(reference.encoded)\" parentID=\"-1\" restricted=\"true\"><dc:title></dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">\(description)</desc></item></DIDL-Lite>"
    }

    static func streamDIDL(title: String, artist: String, album: String) -> String {
        let safeTitle = escape(title)
        let safeArtist = escape(artist)
        let safeAlbum = escape(album)
        return "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\"><item id=\"-1\" parentID=\"-1\" restricted=\"true\"><dc:title>\(safeTitle)</dc:title><dc:creator>\(safeArtist)</dc:creator><upnp:artist>\(safeArtist)</upnp:artist><upnp:album>\(safeAlbum)</upnp:album><upnp:class>object.item.audioItem.musicTrack</upnp:class></item></DIDL-Lite>"
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func normalizedUUID(_ value: String) -> String {
        value.replacingOccurrences(of: "uuid:", with: "", options: [.caseInsensitive, .anchored])
    }
}

private final class SonosMusicFlatXMLParser: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var stack: [(name: String, text: String)] = []

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append((elementName.split(separator: ":").last.map(String.init) ?? elementName, ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let completed = stack.popLast() else { return }
        let value = completed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { values[completed.name] = value }
        if !stack.isEmpty { stack[stack.count - 1].text += completed.text }
    }
}

private final class SonosMusicTopologyParser: NSObject, XMLParserDelegate {
    private struct Member {
        let room: String
        let location: String
        let uuid: String
    }
    private struct Group {
        let coordinatorUUID: String
        let members: [Member]
    }

    private var groups: [Group] = []
    private var currentCoordinator = ""
    private var currentMembers: [Member] = []

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "ZoneGroup" {
            currentCoordinator = attributes["Coordinator"] ?? ""
            currentMembers = []
        } else if name == "ZoneGroupMember", !currentCoordinator.isEmpty {
            currentMembers.append(Member(
                room: attributes["ZoneName"] ?? "",
                location: attributes["Location"] ?? "",
                uuid: attributes["UUID"] ?? ""
            ))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard name == "ZoneGroup", !currentCoordinator.isEmpty else { return }
        groups.append(Group(coordinatorUUID: currentCoordinator, members: currentMembers))
        currentCoordinator = ""
        currentMembers = []
    }

    func coordinator(roomName: String) -> SonosCoordinator? {
        guard let group = groups.first(where: {
            $0.members.contains { $0.room.caseInsensitiveCompare(roomName) == .orderedSame }
        }) else { return nil }
        let member = group.members.first(where: { $0.uuid == group.coordinatorUUID })
            ?? group.members.first(where: { $0.room.caseInsensitiveCompare(roomName) == .orderedSame })
        guard let member, let url = URL(string: member.location), let host = url.host else { return nil }
        return SonosCoordinator(host: host, port: url.port ?? 1400, uuid: group.coordinatorUUID)
    }
}
