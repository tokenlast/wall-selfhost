import Foundation

struct SonosEndpoint: Equatable, Hashable {
    var host: String
    var port: Int
    var roomName: String

    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        return components.url
    }
}

enum SonosTransportState: String, Equatable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case transitioning = "TRANSITIONING"
    case stopped = "STOPPED"
    case noMedia = "NO_MEDIA_PRESENT"
    case unknown = "UNKNOWN"

    init(soapValue: String?) {
        self = SonosTransportState(rawValue: soapValue?.uppercased() ?? "") ?? .unknown
    }

    var isPlaying: Bool { self == .playing }
}

struct SonosTrackMetadata: Equatable {
    var title: String
    var artist: String
    var album: String
    var albumArtURI: String

    init(title: String, artist: String, album: String, albumArtURI: String = "") {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURI = albumArtURI
    }

    static let empty = SonosTrackMetadata(title: "", artist: "", album: "")
}

struct SonosNowPlayingSnapshot: Equatable {
    var speakerName: String
    var title: String
    var artist: String
    var album: String
    var albumArtURL: URL?
    var sourceURI: String
    var transportState: SonosTransportState
    var volume: Int

    init(
        speakerName: String,
        title: String,
        artist: String,
        album: String,
        albumArtURL: URL? = nil,
        sourceURI: String = "",
        transportState: SonosTransportState,
        volume: Int
    ) {
        self.speakerName = speakerName
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURL = albumArtURL
        self.sourceURI = sourceURI
        self.transportState = transportState
        self.volume = volume
    }

    static let empty = SonosNowPlayingSnapshot(
        speakerName: "Sonos",
        title: "Nothing playing",
        artist: "",
        album: "",
        transportState: .unknown,
        volume: 0
    )

    var isPlaying: Bool { transportState.isPlaying }
}

struct SonosVolumeReconciliation {
    static func value(polled: Int?, previous: Int) -> Int {
        min(max(polled ?? previous, 0), 100)
    }
}

enum SonosConnectionState: Equatable {
    case idle
    case discovering
    case connected
    case unavailable(String)
}

enum SonosRequestError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
}

/// Pure SOAP construction and parsing helpers, deliberately internal so unit
/// tests can exercise real Sonos payloads through @testable import.
enum SonosSOAP {
    static let avTransportService = "urn:schemas-upnp-org:service:AVTransport:1"
    static let renderingControlService = "urn:schemas-upnp-org:service:RenderingControl:1"
    static let avTransportPath = "MediaRenderer/AVTransport/Control"
    static let renderingControlPath = "MediaRenderer/RenderingControl/Control"

    static func makeRequest(
        baseURL: URL,
        path: String,
        service: String,
        action: String,
        body: String,
        timeout: TimeInterval = 5
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = envelope(service: service, action: action, body: body)
        return request
    }

    static func envelope(service: String, action: String, body: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body><u:\(action) xmlns:u="\(service)">\(body)</u:\(action)></s:Body>
        </s:Envelope>
        """
        return Data(xml.utf8)
    }

    static func transportInfoRequest(baseURL: URL) -> URLRequest {
        makeRequest(
            baseURL: baseURL,
            path: avTransportPath,
            service: avTransportService,
            action: "GetTransportInfo",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    static func positionInfoRequest(baseURL: URL) -> URLRequest {
        makeRequest(
            baseURL: baseURL,
            path: avTransportPath,
            service: avTransportService,
            action: "GetPositionInfo",
            body: "<InstanceID>0</InstanceID>"
        )
    }

    static func volumeRequest(baseURL: URL) -> URLRequest {
        makeRequest(
            baseURL: baseURL,
            path: renderingControlPath,
            service: renderingControlService,
            action: "GetVolume",
            body: "<InstanceID>0</InstanceID><Channel>Master</Channel>"
        )
    }

    static func deviceDescriptionRequest(baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("xml/device_description.xml"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        return request
    }

    static func transportCommandRequest(baseURL: URL, action: String) -> URLRequest {
        let speed = action == "Play" ? "<Speed>1</Speed>" : ""
        return makeRequest(
            baseURL: baseURL,
            path: avTransportPath,
            service: avTransportService,
            action: action,
            body: "<InstanceID>0</InstanceID>\(speed)"
        )
    }

    static func setVolumeRequest(baseURL: URL, volume: Int) -> URLRequest {
        let clamped = min(max(volume, 0), 100)
        return makeRequest(
            baseURL: baseURL,
            path: renderingControlPath,
            service: renderingControlService,
            action: "SetVolume",
            body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(clamped)</DesiredVolume>"
        )
    }

    static func playModeRequest(baseURL: URL, mode: String) -> URLRequest {
        makeRequest(
            baseURL: baseURL,
            path: avTransportPath,
            service: avTransportService,
            action: "SetPlayMode",
            body: "<InstanceID>0</InstanceID><NewPlayMode>\(mode)</NewPlayMode>"
        )
    }

    static func parseTransportState(from data: Data) -> SonosTransportState? {
        let values = SonosXMLValues(data: data)
        guard let raw = values.values["CurrentTransportState"] else { return nil }
        return SonosTransportState(soapValue: raw)
    }

    static func parseVolume(from data: Data) -> Int? {
        let values = SonosXMLValues(data: data)
        guard let value = values.values["CurrentVolume"], let volume = Int(value) else { return nil }
        return min(max(volume, 0), 100)
    }

    static func parseTrackMetadata(from positionInfoData: Data) -> SonosTrackMetadata {
        let outer = SonosXMLValues(data: positionInfoData)
        guard let metadata = outer.values["TrackMetaData"],
              !metadata.isEmpty, metadata != "NOT_IMPLEMENTED",
              let data = metadata.data(using: .utf8) else {
            return .empty
        }
        let values = SonosXMLValues(data: data)
        var title = values.values["title"] ?? ""
        var artist = values.values["creator"] ?? values.values["artist"] ?? ""
        let album = values.values["album"] ?? ""
        let albumArtURI = values.values["albumArtURI"] ?? ""

        // Radio and line-in sources often put the human-readable song in
        // r:streamContent instead of dc:title/dc:creator.
        if let stream = values.values["streamContent"], !stream.isEmpty, stream != "zpstr_buffering" {
            let pieces = stream.components(separatedBy: " - ")
            if title.isEmpty { title = pieces.count > 1 ? pieces.dropFirst().joined(separator: " - ") : stream }
            if artist.isEmpty, pieces.count > 1 { artist = pieces[0] }
        }
        return SonosTrackMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtURI: albumArtURI
        )
    }

    static func parseRoomName(from deviceDescriptionData: Data) -> String? {
        let values = SonosXMLValues(data: deviceDescriptionData)
        for key in ["roomName", "displayName", "friendlyName"] {
            if let value = values.values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value.replacingOccurrences(of: " - Sonos", with: "")
            }
        }
        return nil
    }

    static func validatedData(for request: URLRequest, using session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SonosRequestError.invalidResponse }
        guard 200..<300 ~= response.statusCode else { throw SonosRequestError.httpStatus(response.statusCode) }
        guard !data.isEmpty else {
            // Sonos transport commands commonly return a valid, empty 200.
            if request.httpMethod == "POST", request.value(forHTTPHeaderField: "SOAPACTION")?.contains("#Get") == false {
                return data
            }
            throw SonosRequestError.emptyResponse
        }
        return data
    }
}

private final class SonosXMLValues: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var stack: [(name: String, text: String)] = []

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        stack.append((Self.localName(elementName), ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let completed = stack.popLast() else { return }
        let value = completed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { values[completed.name] = value }
        if !stack.isEmpty { stack[stack.count - 1].text += completed.text }
    }

    private static func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init) ?? value
    }
}

@MainActor
final class SonosNowPlayingService: NSObject, ObservableObject {
    @Published private(set) var snapshot = SonosNowPlayingSnapshot.empty
    @Published private(set) var connectionState: SonosConnectionState = .idle
    @Published private(set) var isSendingCommand = false
    @Published private(set) var isShuffleEnabled = false

    private let session: URLSession
    private let defaults: UserDefaults
    private var endpoint: SonosEndpoint?
    private var pollingTask: Task<Void, Never>?
    private var volumeCommandTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var isRefreshing = false

    private var browser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []
    private var discoveredEndpoints: [SonosEndpoint] = []
    private var discoveryContinuation: CheckedContinuation<[SonosEndpoint], Never>?
    private var discoveryTimeoutTask: Task<Void, Never>?

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        super.init()
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        volumeCommandTask?.cancel()
        volumeCommandTask = nil
        finishDiscovery(with: discoveredEndpoints)
    }

    func retryDiscovery() {
        endpoint = nil
        consecutiveFailures = 0
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if endpoint == nil {
            await connectToSpeaker()
            return
        }
        await pollCurrentEndpoint()
    }

    func togglePlayPause() {
        let action = snapshot.isPlaying ? "Pause" : "Play"
        Task { await sendTransportCommand(action) }
    }

    func skipForward() {
        Task {
            if SiftSonosService.shared.activeShuffleState != nil {
                _ = await SiftSonosService.shared.control(action: "next")
                await refresh()
            } else {
                await sendTransportCommand("Next")
            }
        }
    }

    func skipBackward() {
        Task {
            if SiftSonosService.shared.activeShuffleState != nil {
                _ = await SiftSonosService.shared.control(action: "previous")
                await refresh()
            } else {
                await sendTransportCommand("Previous")
            }
        }
    }

    func toggleShuffle() {
        if let enabled = SiftSonosService.shared.toggleShuffleIfActive() {
            isShuffleEnabled = enabled
            return
        }
        Task { await sendShuffleCommand() }
    }

    func setVolume(_ volume: Int) {
        let clamped = min(max(volume, 0), 100)
        snapshot.volume = clamped
        volumeCommandTask?.cancel()
        volumeCommandTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            await self?.sendVolumeCommand(clamped)
        }
    }

    static func fetchSnapshot(
        endpoint: SonosEndpoint,
        session: URLSession = .shared,
        fallbackVolume: Int = 0
    ) async throws -> SonosNowPlayingSnapshot {
        guard let baseURL = endpoint.baseURL else { throw SonosRequestError.invalidURL }

        async let transportResult = optionalData(for: SonosSOAP.transportInfoRequest(baseURL: baseURL), session: session)
        async let positionResult = optionalData(for: SonosSOAP.positionInfoRequest(baseURL: baseURL), session: session)
        async let volumeResult = optionalData(for: SonosSOAP.volumeRequest(baseURL: baseURL), session: session)
        let (transportData, positionData, volumeData) = await (transportResult, positionResult, volumeResult)

        guard transportData != nil || positionData != nil || volumeData != nil else {
            throw SonosRequestError.invalidResponse
        }
        let state = transportData.flatMap(SonosSOAP.parseTransportState) ?? .unknown
        let metadata = positionData.map(SonosSOAP.parseTrackMetadata) ?? .empty
        let sourceURI = positionData.flatMap { SonosMusicXML.flatValues(in: $0)["TrackURI"] } ?? ""
        let albumArtURL: URL?
        if metadata.albumArtURI.isEmpty {
            albumArtURL = nil
        } else if let absolute = URL(string: metadata.albumArtURI), absolute.scheme != nil {
            albumArtURL = absolute
        } else if let baseURL = endpoint.baseURL {
            albumArtURL = URL(string: metadata.albumArtURI, relativeTo: baseURL)?.absoluteURL
        } else {
            albumArtURL = nil
        }
        let volume = SonosVolumeReconciliation.value(
            polled: volumeData.flatMap(SonosSOAP.parseVolume),
            previous: fallbackVolume
        )
        let fallbackTitle: String
        switch state {
        case .playing, .paused, .transitioning: fallbackTitle = "Live audio"
        default: fallbackTitle = "Nothing playing"
        }
        return SonosNowPlayingSnapshot(
            speakerName: endpoint.roomName.isEmpty ? "Sonos" : endpoint.roomName,
            title: metadata.title.isEmpty ? fallbackTitle : metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            albumArtURL: albumArtURL,
            sourceURI: sourceURI,
            transportState: state,
            volume: volume
        )
    }

    private static func optionalData(for request: URLRequest, session: URLSession) async -> Data? {
        try? await SonosSOAP.validatedData(for: request, using: session)
    }

    private func connectToSpeaker() async {
        connectionState = .discovering
        var candidates: [SonosEndpoint] = []

        if let host = defaults.string(forKey: "wall.sonos.host"), !host.isEmpty {
            candidates.append(SonosEndpoint(
                host: host,
                // Sonos advertises port 1443 for its newer WebSocket service.
                // UPnP AVTransport/RenderingControl SOAP remains on 1400.
                port: 1400,
                roomName: defaults.string(forKey: "wall.sonos.room") ?? "Sonos"
            ))
        }
        let discovered = await discoverEndpoints()
        for endpoint in discovered where !candidates.contains(where: { $0.host == endpoint.host && $0.port == endpoint.port }) {
            candidates.append(endpoint)
        }

        var best: (endpoint: SonosEndpoint, snapshot: SonosNowPlayingSnapshot, score: Int)?
        for var candidate in candidates {
            if let roomName = await roomName(for: candidate) { candidate.roomName = roomName }
            guard let candidateSnapshot = try? await Self.fetchSnapshot(endpoint: candidate, session: session) else { continue }
            let score = Self.selectionScore(candidateSnapshot)
            if best == nil || score > best!.score {
                best = (candidate, candidateSnapshot, score)
            }
        }

        guard let best else {
            endpoint = nil
            connectionState = .unavailable("No Sonos found on this Wi-Fi")
            return
        }
        endpoint = best.endpoint
        snapshot = await applyingSiftMetadata(to: best.snapshot)
        connectionState = .connected
        consecutiveFailures = 0
        defaults.set(best.endpoint.host, forKey: "wall.sonos.host")
        defaults.set(best.endpoint.port, forKey: "wall.sonos.port")
        defaults.set(best.endpoint.roomName, forKey: "wall.sonos.room")
    }

    private func pollCurrentEndpoint() async {
        guard let endpoint else { return }
        do {
            let fetched = try await Self.fetchSnapshot(
                endpoint: endpoint,
                session: session,
                fallbackVolume: snapshot.volume
            )
            snapshot = await applyingSiftMetadata(to: fetched)
            if let siftShuffle = SiftSonosService.shared.activeShuffleState {
                isShuffleEnabled = siftShuffle
            }
            connectionState = .connected
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= 2 {
                self.endpoint = nil
                connectionState = .unavailable("Sonos went offline")
            }
        }
    }

    private func sendTransportCommand(_ action: String) async {
        if endpoint == nil { await connectToSpeaker() }
        guard let endpoint, let baseURL = endpoint.baseURL else { return }
        isSendingCommand = true
        defer { isSendingCommand = false }
        do {
            _ = try await SonosSOAP.validatedData(
                for: SonosSOAP.transportCommandRequest(baseURL: baseURL, action: action),
                using: session
            )
            if action == "Play" { snapshot.transportState = .playing }
            if action == "Pause" { snapshot.transportState = .paused }
            try? await Task.sleep(nanoseconds: 250_000_000)
            await pollCurrentEndpoint()
        } catch {
            connectionState = .unavailable("Sonos didn't accept that command")
        }
    }

    private func sendVolumeCommand(_ volume: Int) async {
        if endpoint == nil { await connectToSpeaker() }
        guard let endpoint, let baseURL = endpoint.baseURL else { return }
        isSendingCommand = true
        defer { isSendingCommand = false }
        do {
            _ = try await SonosSOAP.validatedData(
                for: SonosSOAP.setVolumeRequest(baseURL: baseURL, volume: volume),
                using: session
            )
        } catch {
            connectionState = .unavailable("Sonos didn't accept that volume")
        }
    }

    private func sendShuffleCommand() async {
        if endpoint == nil { await connectToSpeaker() }
        guard let endpoint, let baseURL = endpoint.baseURL else { return }
        let next = !isShuffleEnabled
        isSendingCommand = true
        defer { isSendingCommand = false }
        do {
            _ = try await SonosSOAP.validatedData(
                for: SonosSOAP.playModeRequest(
                    baseURL: baseURL,
                    mode: next ? "SHUFFLE" : SonosQueueContinuationPolicy.playMode
                ),
                using: session
            )
            isShuffleEnabled = next
        } catch {
            connectionState = .unavailable("Sonos didn't accept shuffle")
        }
    }

    private func applyingSiftMetadata(
        to snapshot: SonosNowPlayingSnapshot
    ) async -> SonosNowPlayingSnapshot {
        guard let siftHost = WallConfiguration.siftURL.host,
              snapshot.sourceURI.localizedCaseInsensitiveContains(siftHost),
              let track = await SiftSonosService.shared.track(matchingSonosURI: snapshot.sourceURI) else {
            return snapshot
        }
        var enriched = snapshot
        enriched.title = track.title
        enriched.artist = track.artist
        enriched.album = track.album
        enriched.albumArtURL = SiftSonosService.shared.artworkURL(for: track)
        return enriched
    }

    private func roomName(for endpoint: SonosEndpoint) async -> String? {
        guard let baseURL = endpoint.baseURL,
              let data = try? await SonosSOAP.validatedData(
                for: SonosSOAP.deviceDescriptionRequest(baseURL: baseURL),
                using: session
              ) else { return nil }
        return SonosSOAP.parseRoomName(from: data)
    }

    private static func selectionScore(_ snapshot: SonosNowPlayingSnapshot) -> Int {
        var score = 0
        if snapshot.transportState == .playing { score += 100 }
        if snapshot.transportState == .paused { score += 80 }
        if snapshot.title != "Nothing playing" && snapshot.title != "Live audio" { score += 30 }
        return score
    }
}

extension SonosNowPlayingService: NetServiceBrowserDelegate, NetServiceDelegate {
    private func discoverEndpoints() async -> [SonosEndpoint] {
        guard discoveryContinuation == nil else { return discoveredEndpoints }
        return await withCheckedContinuation { continuation in
            discoveryContinuation = continuation
            discoveredEndpoints = []
            resolvingServices = []

            let browser = NetServiceBrowser()
            self.browser = browser
            browser.delegate = self
            browser.searchForServices(ofType: "_sonos._tcp.", inDomain: "local.")

            discoveryTimeoutTask?.cancel()
            discoveryTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishDiscovery(with: self?.discoveredEndpoints ?? [])
            }
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            resolvingServices.append(service)
            service.delegate = self
            service.resolve(withTimeout: 2.5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor [weak self] in
            guard let self,
                  let rawHost = sender.hostName else { return }
            let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let endpoint = SonosEndpoint(
                host: host,
                // `_sonos._tcp` commonly resolves to WSS port 1443; it is not
                // the UPnP control endpoint used by the actions in this file.
                port: 1400,
                roomName: sender.name
            )
            if !discoveredEndpoints.contains(where: { $0.host == endpoint.host && $0.port == endpoint.port }) {
                discoveredEndpoints.append(endpoint)
            }
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        Task { @MainActor [weak self] in
            self?.finishDiscovery(with: self?.discoveredEndpoints ?? [])
        }
    }

    private func finishDiscovery(with endpoints: [SonosEndpoint]) {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        browser?.stop()
        browser = nil
        resolvingServices.removeAll()
        guard let continuation = discoveryContinuation else { return }
        discoveryContinuation = nil
        continuation.resume(returning: endpoints)
    }
}
