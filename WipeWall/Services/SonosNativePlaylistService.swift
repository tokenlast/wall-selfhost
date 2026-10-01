import Foundation

struct SonosNativePlaylist: Identifiable, Equatable {
    let id: String
    let title: String
    let artworkURL: URL?
    let subtitle: String

    init(id: String, title: String, artworkURL: URL?, subtitle: String = "") {
        self.id = id
        self.title = title
        self.artworkURL = artworkURL
        self.subtitle = subtitle
    }
}

enum SpotifyCollectionSearchKind: String, CaseIterable, Identifiable {
    case album
    case playlist

    var id: String { rawValue }
}

actor SonosNativePlaylistService {
    static let shared = SonosNativePlaylistService()

    private let session: URLSession
    private let defaults: UserDefaults

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    func playlists(for source: WallMusicSource) async throws -> [SonosNativePlaylist] {
        let context = try await context(for: source)
        for category in ["playlists", "my_playlists", "user:playlists", "favorites:playlists"] {
            if let data = try? await smapi(
                action: "getMetadata",
                context: context,
                body: "<id>\(SonosMusicXML.escape(category))</id><index>0</index><count>200</count>"
            ) {
                let rows = SonosNativePlaylistParser(data: data).playlists
                if !rows.isEmpty { return rows }
            }
        }
        return []
    }

    /// Searches Spotify through the account already linked to Sonos. This
    /// returns native Spotify collection IDs, so playback opens the selected
    /// album/playlist itself rather than trying to resolve its display text as
    /// an unrelated track.
    func searchSpotify(
        query rawQuery: String,
        kind: SpotifyCollectionSearchKind
    ) async throws -> [SonosNativePlaylist] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let context = try await context(for: .spotify)
        let categories: [String]
        switch kind {
        case .album:
            categories = ["albums", "search:albums", "album"]
        case .playlist:
            categories = ["playlists", "search:playlists", "playlist"]
        }

        for category in categories {
            if let data = try? await smapi(
                action: "search",
                context: context,
                body: "<id>\(SonosMusicXML.escape(category))</id><term>\(SonosMusicXML.escape(query))</term><index>0</index><count>40</count>"
            ) {
                let rows = SonosNativePlaylistParser(data: data).playlists
                if !rows.isEmpty {
                    var seen = Set<String>()
                    return rows.filter { seen.insert($0.id).inserted }
                }
            }
        }
        throw SoundCloudSonosFailure.searchUnavailable
    }

    func play(_ playlist: SonosNativePlaylist, source: WallMusicSource) async -> String {
        do {
            let context = try await context(for: source)
            let tracks = try await tracks(in: playlist, context: context)
            guard !tracks.isEmpty else { throw SoundCloudSonosFailure.trackUnavailable }

            try await clearQueue(coordinator: context.coordinator)
            var firstPosition: Int?
            for track in tracks {
                let mediaData = try await smapi(
                    action: "getMediaURI",
                    context: context,
                    body: "<id>\(SonosMusicXML.escape(track.id))</id>"
                )
                let values = SonosMusicXML.flatValues(in: mediaData)
                guard let stream = values["getMediaURIResult"] ?? values["mediaURI"] ?? values["uri"] else {
                    continue
                }
                let position = try await enqueue(
                    track: track,
                    stream: stream,
                    asNext: SonosQueueContinuationPolicy.appendToEnd,
                    coordinator: context.coordinator
                )
                firstPosition = firstPosition ?? position
            }
            guard let firstPosition else { throw SoundCloudSonosFailure.queueRejected }
            try await bindAndPlay(queuePosition: firstPosition, coordinator: context.coordinator)
            return "Playing \(playlist.title) from \(source.rawValue) on the Living Room Sonos."
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "Playlist playback failed."
            return "I couldn’t play that on Sonos. \(detail)"
        }
    }

    private func tracks(in collection: SonosNativePlaylist, context: Context) async throws -> [SonosNativeTrack] {
        let pageSize = 100
        var tracks: [SonosNativeTrack] = []
        var seen = Set<String>()

        for page in 0..<10 {
            let pageTracks: [SonosNativeTrack]
            do {
                let data = try await smapi(
                    action: "getMetadata",
                    context: context,
                    body: "<id>\(SonosMusicXML.escape(collection.id))</id><index>\(page * pageSize)</index><count>\(pageSize)</count>"
                )
                pageTracks = SonosNativeTrackParser(data: data).tracks
            } catch {
                if tracks.isEmpty { throw error }
                break
            }

            var added = 0
            for track in pageTracks where seen.insert(track.id).inserted {
                tracks.append(track)
                added += 1
            }
            if pageTracks.count < pageSize || added == 0 { break }
        }
        return tracks
    }

    private struct Context {
        let coordinator: SonosCoordinator
        let endpoint: URL
        let token: String
        let key: String
        let householdID: String
        let deviceID: String
    }

    private func context(for source: WallMusicSource) async throws -> Context {
        let coordinator = try await resolveLivingRoomCoordinator()
        let descriptor = try await serviceDescriptor(for: source, coordinator: coordinator)
        let account = try await account(for: descriptor.serviceType, coordinator: coordinator)
        let status = try await get(coordinator.baseURL.appendingPathComponent("status/zp"))
        let statusValues = SonosMusicXML.flatValues(in: status)
        let household = statusValues["HouseholdControlID"]
            ?? statusValues["HouseholdID"]
            ?? account.householdID
        guard let household, !household.isEmpty else { throw SoundCloudSonosFailure.accountNotLinked }
        return Context(
            coordinator: coordinator,
            endpoint: descriptor.endpoint,
            token: account.token,
            key: account.key,
            householdID: household,
            deviceID: SonosMusicXML.normalizedUUID(coordinator.uuid)
        )
    }

    private struct Descriptor {
        let serviceType: Int
        let endpoint: URL
    }

    private struct Account {
        let token: String
        let key: String
        let householdID: String?
    }

    private func serviceDescriptor(for source: WallMusicSource, coordinator: SonosCoordinator) async throws -> Descriptor {
        let request = SonosSOAP.makeRequest(
            baseURL: coordinator.baseURL,
            path: "MusicServices/Control",
            service: "urn:schemas-upnp-org:service:MusicServices:1",
            action: "ListAvailableServices",
            body: "",
            timeout: 7
        )
        let data = try await SonosSOAP.validatedData(for: request, using: session)
        guard let xml = SonosMusicXML.flatValues(in: data)["AvailableServiceDescriptorList"],
              let xmlData = xml.data(using: .utf8) else {
            throw SoundCloudSonosFailure.searchUnavailable
        }
        let expectedName = source == .spotify ? "spotify" : "soundcloud"
        guard let service = SonosServiceDescriptorParser(data: xmlData).services.first(where: {
            $0.name.lowercased().contains(expectedName)
        }) else {
            throw SoundCloudSonosFailure.accountNotLinked
        }
        return Descriptor(serviceType: service.id * 256 + 7, endpoint: service.endpoint)
    }

    private func account(for serviceType: Int, coordinator: SonosCoordinator) async throws -> Account {
        let data = try await get(coordinator.baseURL.appendingPathComponent("status/accounts"))
        guard let found = SonosProviderAccountParser(data: data, serviceType: serviceType).account else {
            throw SoundCloudSonosFailure.accountNotLinked
        }
        return Account(token: found.token, key: found.key, householdID: found.householdID)
    }

    private func smapi(action: String, context: Context, body: String) async throws -> Data {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
          <soap:Header><credentials xmlns="http://www.sonos.com/Services/1.1"><deviceId>\(SonosMusicXML.escape(context.deviceID))</deviceId><deviceProvider>Sonos</deviceProvider><loginToken><token>\(SonosMusicXML.escape(context.token))</token><key>\(SonosMusicXML.escape(context.key))</key><householdId>\(SonosMusicXML.escape(context.householdID))</householdId></loginToken></credentials></soap:Header>
          <soap:Body><\(action) xmlns="http://www.sonos.com/Services/1.1">\(body)</\(action)></soap:Body>
        </soap:Envelope>
        """
        var request = URLRequest(url: context.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"http://www.sonos.com/Services/1.1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)
        return try await SonosSOAP.validatedData(for: request, using: session)
    }

    private func resolveLivingRoomCoordinator() async throws -> SonosCoordinator {
        let hosts = [defaults.string(forKey: "wall.sonos.host")].compactMap { $0 }
        var visited = Set<String>()
        for host in hosts where visited.insert(host).inserted {
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
                  let coordinator = SonosMusicXML.coordinator(in: topology, roomName: "Living Room") else { continue }
            defaults.set(coordinator.host, forKey: "wall.sonos.host")
            return coordinator
        }
        throw SoundCloudSonosFailure.speakerUnavailable
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        return try await SonosSOAP.validatedData(for: request, using: session)
    }

    private func enqueue(
        track: SonosNativeTrack,
        stream: String,
        asNext: Int,
        coordinator: SonosCoordinator
    ) async throws -> Int {
        let metadata = SonosMusicXML.streamDIDL(title: track.title, artist: track.artist, album: track.album)
        let body = """
        <InstanceID>0</InstanceID><EnqueuedURI>\(SonosMusicXML.escape(stream))</EnqueuedURI><EnqueuedURIMetaData>\(SonosMusicXML.escape(metadata))</EnqueuedURIMetaData><DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>\(asNext)</EnqueueAsNext>
        """
        let data = try await localSOAP(coordinator, action: "AddURIToQueue", body: body)
        guard let raw = SonosMusicXML.flatValues(in: data)["FirstTrackNumberEnqueued"],
              let position = Int(raw), position > 0 else { throw SoundCloudSonosFailure.queueRejected }
        return position
    }

    private func clearQueue(coordinator: SonosCoordinator) async throws {
        _ = try await localSOAP(
            coordinator,
            action: "RemoveAllTracksFromQueue",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    private func bindAndPlay(queuePosition: Int, coordinator: SonosCoordinator) async throws {
        let uuid = SonosMusicXML.normalizedUUID(coordinator.uuid)
        _ = try await localSOAP(coordinator, action: "SetAVTransportURI", body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon-queue:\(uuid)#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>")
        _ = try await localSOAP(coordinator, action: "Seek", body: "<InstanceID>0</InstanceID><Unit>TRACK_NR</Unit><Target>\(queuePosition)</Target>")
        _ = try? await localSOAP(coordinator, action: "SetPlayMode", body: "<InstanceID>0</InstanceID><NewPlayMode>\(SonosQueueContinuationPolicy.replacementPlayMode)</NewPlayMode>")
        _ = try await localSOAP(coordinator, action: "Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    private func localSOAP(_ coordinator: SonosCoordinator, action: String, body: String) async throws -> Data {
        let request = SonosSOAP.makeRequest(
            baseURL: coordinator.baseURL,
            path: SonosSOAP.avTransportPath,
            service: SonosSOAP.avTransportService,
            action: action,
            body: body,
            timeout: 8
        )
        return try await SonosSOAP.validatedData(for: request, using: session)
    }
}

private struct SonosNativeTrack {
    let id: String
    let title: String
    let artist: String
    let album: String
}

private final class SonosServiceDescriptorParser: NSObject, XMLParserDelegate {
    struct Service {
        let id: Int
        let name: String
        let endpoint: URL
    }

    private(set) var services: [Service] = []

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard elementName.split(separator: ":").last == "Service",
              let id = attributes["Id"].flatMap(Int.init),
              let name = attributes["Name"],
              let endpoint = (attributes["SecureUri"] ?? attributes["Uri"]).flatMap(URL.init(string:)) else { return }
        services.append(Service(id: id, name: name, endpoint: endpoint))
    }
}

private final class SonosProviderAccountParser: NSObject, XMLParserDelegate {
    struct FoundAccount {
        let token: String
        let key: String
        let householdID: String?
    }

    private(set) var account: FoundAccount?
    private let serviceType: Int
    private var collecting = false
    private var currentText = ""
    private var values: [String: String] = [:]

    init(data: Data, serviceType: Int) {
        self.serviceType = serviceType
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        currentText = ""
        if elementName.split(separator: ":").last == "Account" {
            collecting = attributes["Deleted"] != "1" && attributes["ServiceType"] == String(serviceType)
            if collecting { values = attributes }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if collecting {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[name] = value }
        }
        if name == "Account", collecting {
            let token = values["Token"] ?? values["OAuthToken"] ?? ""
            let key = values["Key"] ?? values["OAuthKey"] ?? ""
            if !token.isEmpty, !key.isEmpty {
                account = FoundAccount(
                    token: token,
                    key: key,
                    householdID: values["HouseholdID"] ?? values["HouseholdControlID"]
                )
                parser.abortParsing()
            }
            collecting = false
        }
        currentText = ""
    }
}

private final class SonosNativePlaylistParser: NSObject, XMLParserDelegate {
    private(set) var playlists: [SonosNativePlaylist] = []
    private var collecting = false
    private var depth = 0
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
        if name == "mediaCollection" {
            collecting = true
            depth = 1
            values = [:]
        } else if collecting {
            depth += 1
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if collecting {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[name] = value }
            depth -= 1
            if name == "mediaCollection" || depth == 0 {
                if let id = values["id"], let title = values["title"], !id.isEmpty, !title.isEmpty {
                    playlists.append(SonosNativePlaylist(
                        id: id,
                        title: title,
                        artworkURL: (values["albumArtURI"] ?? values["albumArtURL"]).flatMap(URL.init(string:)),
                        subtitle: values["artist"] ?? values["creator"] ?? values["summary"] ?? ""
                    ))
                }
                collecting = false
            }
        }
        currentText = ""
    }
}

private final class SonosNativeTrackParser: NSObject, XMLParserDelegate {
    private(set) var tracks: [SonosNativeTrack] = []
    private var collecting = false
    private var depth = 0
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
            collecting = true
            depth = 1
            values = [:]
        } else if collecting {
            depth += 1
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if collecting {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[name] = value }
            depth -= 1
            if name == "mediaMetadata" || depth == 0 {
                if let id = values["id"], let title = values["title"], !id.isEmpty, !title.isEmpty {
                    tracks.append(SonosNativeTrack(
                        id: id,
                        title: title,
                        artist: values["artist"] ?? "",
                        album: values["album"] ?? ""
                    ))
                }
                collecting = false
            }
        }
        currentText = ""
    }
}
