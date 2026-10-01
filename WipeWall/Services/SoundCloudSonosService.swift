import Foundation

struct SoundCloudTrackResult: Identifiable, Equatable, Decodable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
}

private struct SoundCloudTrackEnvelope: Decodable {
    let tracks: [SoundCloudTrackResult]
}

/// SoundCloud account tokens and app credentials stay on Joan. The iPad uses
/// only its existing narrow Wall device token to request normalized results.
struct SoundCloudCatalogClient {
    static let shared = SoundCloudCatalogClient()
    let session: URLSession
    let deviceToken: () -> String?

    init(session: URLSession = .shared, deviceToken: @escaping () -> String? = KeychainToken.read) {
        self.session = session
        self.deviceToken = deviceToken
    }

    func searchTracks(query rawQuery: String) async throws -> [SoundCloudTrackResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        guard query.count <= 160 else { throw SoundCloudSonosFailure.searchUnavailable }
        guard let token = deviceToken(), !token.isEmpty else { throw SoundCloudSonosFailure.accountNotLinked }
        var components = URLComponents(url: WallConfiguration.serverURL.appendingPathComponent("api/device/soundcloud/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SoundCloudSonosFailure.searchUnavailable }
        guard 200..<300 ~= response.statusCode else {
            if response.statusCode == 401 || response.statusCode == 503 {
                throw SoundCloudSonosFailure.accountNotLinked
            }
            throw SoundCloudSonosFailure.searchUnavailable
        }
        return try JSONDecoder().decode(SoundCloudTrackEnvelope.self, from: data).tracks
    }
}

enum SoundCloudSonosFailure: LocalizedError {
    case speakerUnavailable
    case accountNotLinked
    case searchUnavailable
    case trackUnavailable
    case queueRejected

    var errorDescription: String? {
        switch self {
        case .speakerUnavailable: return "Living Room Sonos is not available on this Wi-Fi."
        case .accountNotLinked: return "Wall needs its own music-service link."
        case .searchUnavailable: return "SoundCloud search is unavailable."
        case .trackUnavailable: return "SoundCloud could not open that track."
        case .queueRejected: return "Sonos could not add that SoundCloud track."
        }
    }
}

/// Searches the SoundCloud service already linked in Sonos. Wall reads the
/// local player account at request time; service credentials never leave the
/// home network or get persisted by the app.
actor SoundCloudSonosService {
    static let shared = SoundCloudSonosService()

    private let session: URLSession
    private let defaults: UserDefaults
    private let serviceURL = URL(string: "https://api.sonos.integrate.soundcloud.com/")!

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    func search(query rawQuery: String) async throws -> [SoundCloudTrackResult] {
        try await SoundCloudCatalogClient.shared.searchTracks(query: rawQuery)
    }

    private func searchSonos(query rawQuery: String) async throws -> [SoundCloudTrackResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let context = try await context()
        for category in ["tracks", "search:tracks", "search"] {
            if let data = try? await smapi(
                action: "search",
                context: context,
                body: "<id>\(SonosMusicXML.escape(category))</id><term>\(SonosMusicXML.escape(query))</term><index>0</index><count>30</count>"
            ) {
                let tracks = SoundCloudSMAPIParser(data: data).tracks
                if !tracks.isEmpty { return tracks }
            }
        }
        throw SoundCloudSonosFailure.searchUnavailable
    }

    func play(_ track: SoundCloudTrackResult) async -> String {
        do {
            let track = try await playableTrack(for: track)
            let context = try await context()
            let stream = try await mediaStream(for: track, context: context)
            let position = try await enqueue(track: track, stream: stream, coordinator: context.coordinator)
            try await bindAndPlay(queuePosition: position, coordinator: context.coordinator)
            return "Playing \(track.title) by \(track.artist) on the Living Room Sonos."
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "SoundCloud playback failed."
            return "I couldn’t play that on Sonos. \(detail)"
        }
    }

    /// Adds the selected SoundCloud result next without changing the current
    /// Sonos transport or seeking away from the song already playing.
    func queue(_ track: SoundCloudTrackResult) async -> String {
        do {
            let track = try await playableTrack(for: track)
            let context = try await context()
            let stream = try await mediaStream(for: track, context: context)
            _ = try await enqueue(track: track, stream: stream, coordinator: context.coordinator)
            return "Queued \(track.title) by \(track.artist) on the Living Room Sonos."
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "SoundCloud queueing failed."
            return "I couldn’t queue that on Sonos. \(detail)"
        }
    }

    func play(query: String) async -> String {
        do {
            guard let first = try await search(query: query).first else {
                return "I couldn’t play that on Sonos. SoundCloud found no matching tracks."
            }
            return await play(first)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "SoundCloud search failed."
            return "I couldn’t play that on Sonos. \(detail)"
        }
    }

    func queue(query: String) async -> String {
        do {
            guard let first = try await search(query: query).first else {
                return "I couldn’t queue that on Sonos. SoundCloud found no matching tracks."
            }
            return await queue(first)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "SoundCloud search failed."
            return "I couldn’t queue that on Sonos. \(detail)"
        }
    }

    private func playableTrack(for catalogTrack: SoundCloudTrackResult) async throws -> SoundCloudTrackResult {
        // SoundCloud's public API URN is not the Sonos SMAPI item ID. Resolve
        // the exact display result against the linked Sonos account only at
        // playback time, so catalog search remains reliable and account-aware.
        guard catalogTrack.id.hasPrefix("soundcloud:tracks:") else { return catalogTrack }
        let query = [catalogTrack.title, catalogTrack.artist].filter { !$0.isEmpty }.joined(separator: " ")
        let candidates = try await searchSonos(query: query)
        let title = catalogTrack.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let artist = catalogTrack.artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let exact = candidates.first(where: { candidate in
            let candidateTitle = candidate.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let candidateArtist = candidate.artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return candidateTitle == title && (artist.isEmpty || candidateArtist == artist)
        }) {
            return exact
        }
        guard let first = candidates.first else { throw SoundCloudSonosFailure.trackUnavailable }
        return first
    }

    private struct Context {
        let coordinator: SonosCoordinator
        let account: SoundCloudSonosAccount
        let deviceID: String
        let householdID: String
    }

    private func mediaStream(for track: SoundCloudTrackResult, context: Context) async throws -> String {
        let mediaData = try await smapi(
            action: "getMediaURI",
            context: context,
            body: "<id>\(SonosMusicXML.escape(track.id))</id>"
        )
        let values = SonosMusicXML.flatValues(in: mediaData)
        guard let stream = values["getMediaURIResult"] ?? values["mediaURI"] ?? values["uri"],
              let streamURL = URL(string: stream),
              ["http", "https"].contains(streamURL.scheme?.lowercased() ?? "") else {
            throw SoundCloudSonosFailure.trackUnavailable
        }
        return stream
    }

    private func context() async throws -> Context {
        let coordinator = try await resolveLivingRoomCoordinator()
        var accountRequest = URLRequest(url: coordinator.baseURL.appendingPathComponent("status/accounts"))
        accountRequest.timeoutInterval = 5
        let accountData = try await SonosSOAP.validatedData(for: accountRequest, using: session)
        guard let account = SoundCloudSonosAccountParser(data: accountData).account else {
            throw SoundCloudSonosFailure.accountNotLinked
        }

        var statusRequest = URLRequest(url: coordinator.baseURL.appendingPathComponent("status/zp"))
        statusRequest.timeoutInterval = 5
        let statusData = try? await SonosSOAP.validatedData(for: statusRequest, using: session)
        let values = statusData.map(SonosMusicXML.flatValues(in:)) ?? [:]
        let household = values["HouseholdControlID"]
            ?? values["HouseholdID"]
            ?? account.householdID
        guard let household, !household.isEmpty else {
            throw SoundCloudSonosFailure.accountNotLinked
        }
        return Context(
            coordinator: coordinator,
            account: account,
            deviceID: SonosMusicXML.normalizedUUID(coordinator.uuid),
            householdID: household
        )
    }

    private func smapi(action: String, context: Context, body: String) async throws -> Data {
        let credentials = """
        <credentials xmlns="http://www.sonos.com/Services/1.1">
          <deviceId>\(SonosMusicXML.escape(context.deviceID))</deviceId>
          <deviceProvider>Sonos</deviceProvider>
          <loginToken>
            <token>\(SonosMusicXML.escape(context.account.token))</token>
            <key>\(SonosMusicXML.escape(context.account.key))</key>
            <householdId>\(SonosMusicXML.escape(context.householdID))</householdId>
          </loginToken>
        </credentials>
        """
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Header>\(credentials)</soap:Header>
          <soap:Body><\(action) xmlns="http://www.sonos.com/Services/1.1">\(body)</\(action)></soap:Body>
        </soap:Envelope>
        """
        var request = URLRequest(url: serviceURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"http://www.sonos.com/Services/1.1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)
        return try await SonosSOAP.validatedData(for: request, using: session)
    }

    private func resolveLivingRoomCoordinator() async throws -> SonosCoordinator {
        var hosts = [defaults.string(forKey: "wall.sonos.host")].compactMap { $0 }
        hosts = Array(NSOrderedSet(array: hosts)) as? [String] ?? hosts
        for host in hosts {
            guard let baseURL = URL(string: "http://\(host):1400") else { continue }
            let request = SonosSOAP.makeRequest(
                baseURL: baseURL,
                path: "ZoneGroupTopology/Control",
                service: "urn:schemas-upnp-org:service:ZoneGroupTopology:1",
                action: "GetZoneGroupState",
                body: "",
                timeout: 5
            )
            guard let data = try? await SonosSOAP.validatedData(for: request, using: session),
                  let topology = SonosMusicXML.flatValues(in: data)["ZoneGroupState"],
                  let coordinator = SonosMusicXML.coordinator(in: topology, roomName: "Living Room") else {
                continue
            }
            defaults.set(coordinator.host, forKey: "wall.sonos.host")
            return coordinator
        }
        throw SoundCloudSonosFailure.speakerUnavailable
    }

    private func enqueue(track: SoundCloudTrackResult, stream: String, coordinator: SonosCoordinator) async throws -> Int {
        let metadata = SonosMusicXML.streamDIDL(title: track.title, artist: track.artist, album: track.album)
        let body = """
        <InstanceID>0</InstanceID>
        <EnqueuedURI>\(SonosMusicXML.escape(stream))</EnqueuedURI>
        <EnqueuedURIMetaData>\(SonosMusicXML.escape(metadata))</EnqueuedURIMetaData>
        <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued>
        <EnqueueAsNext>\(SonosQueueContinuationPolicy.enqueueAsNext)</EnqueueAsNext>
        """
        let data = try await localSOAP(coordinator, action: "AddURIToQueue", body: body)
        guard let rawPosition = SonosMusicXML.flatValues(in: data)["FirstTrackNumberEnqueued"],
              let position = Int(rawPosition), position > 0 else {
            throw SoundCloudSonosFailure.queueRejected
        }
        return position
    }

    private func bindAndPlay(queuePosition: Int, coordinator: SonosCoordinator) async throws {
        let uuid = SonosMusicXML.normalizedUUID(coordinator.uuid)
        _ = try await localSOAP(
            coordinator,
            action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon-queue:\(uuid)#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
        )
        _ = try await localSOAP(
            coordinator,
            action: "Seek",
            body: "<InstanceID>0</InstanceID><Unit>TRACK_NR</Unit><Target>\(queuePosition)</Target>"
        )
        _ = try? await localSOAP(
            coordinator,
            action: "SetPlayMode",
            body: "<InstanceID>0</InstanceID><NewPlayMode>\(SonosQueueContinuationPolicy.playMode)</NewPlayMode>"
        )
        _ = try await localSOAP(
            coordinator,
            action: "Play",
            body: "<InstanceID>0</InstanceID><Speed>1</Speed>"
        )
    }

    private func localSOAP(_ coordinator: SonosCoordinator, action: String, body: String) async throws -> Data {
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
}

private struct SoundCloudSonosAccount {
    let token: String
    let key: String
    let householdID: String?
}

private final class SoundCloudSonosAccountParser: NSObject, XMLParserDelegate {
    private(set) var account: SoundCloudSonosAccount?
    private var isSoundCloud = false
    private var values: [String: String] = [:]
    private var currentElement = ""
    private var currentText = ""

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        currentElement = name
        currentText = ""
        if name == "Account" {
            let active = attributes["Deleted"] != "1"
            isSoundCloud = active && attributes["ServiceType"] == "40967"
            if isSoundCloud {
                values = attributes
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if isSoundCloud {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[name] = value }
        }
        if name == "Account", isSoundCloud {
            let token = values["Token"] ?? values["OAuthToken"] ?? ""
            let key = values["Key"] ?? values["OAuthKey"] ?? ""
            if !token.isEmpty, !key.isEmpty {
                account = SoundCloudSonosAccount(
                    token: token,
                    key: key,
                    householdID: values["HouseholdID"] ?? values["HouseholdControlID"]
                )
                parser.abortParsing()
            }
            isSoundCloud = false
        }
        currentElement = ""
        currentText = ""
    }
}

private final class SoundCloudSMAPIParser: NSObject, XMLParserDelegate {
    private(set) var tracks: [SoundCloudTrackResult] = []
    private var insideItem = false
    private var depth = 0
    private var currentElement = ""
    private var currentText = ""
    private var values: [String: String] = [:]

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "mediaMetadata" {
            insideItem = true
            depth = 1
            values = [:]
        } else if insideItem {
            depth += 1
        }
        currentElement = name
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if insideItem {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[name] = value }
            depth -= 1
            if name == "mediaMetadata" || depth == 0 {
                if let id = values["id"], let title = values["title"], !id.isEmpty, !title.isEmpty {
                    tracks.append(SoundCloudTrackResult(
                        id: id,
                        title: title,
                        artist: values["artist"] ?? "",
                        album: values["album"] ?? "",
                        artworkURL: (values["albumArtURI"] ?? values["albumArtURL"]).flatMap(URL.init(string:))
                    ))
                }
                insideItem = false
            }
        }
        currentElement = ""
        currentText = ""
    }
}
