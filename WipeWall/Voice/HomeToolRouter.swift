import Foundation

final class HomeToolRouter {
    private let sonos = SonosLocalController()
    private let sonosMusic = SonosMusicService.shared
    private let fireTV = FireTVController()

    func execute(name: String, arguments: [String: Any]) async -> String {
        switch name {
        case "sonos_control":
            if let action = arguments["action"] as? String,
               let result = await SiftSonosService.shared.control(action: action) {
                return result
            }
            return await sonos.execute(arguments)
        case "sonos_play_music":
            let query = arguments["query"] as? String ?? ""
            switch WallMusicSource.toolSelection(arguments["source"]) {
            case .spotify:
                return await sonosMusic.play(query: query)
            case .soundcloud:
                return await SoundCloudSonosService.shared.play(query: query)
            }
        case "sift_play":
            return await SiftSonosService.shared.play(
                playlist: arguments["playlist"] as? String ?? "queue",
                shuffle: arguments["shuffle"] as? Bool ?? false
            )
        case "sift_add_current_track":
            return await SiftSonosService.shared.addCurrentTrack(
                to: arguments["playlist"] as? String ?? "queue"
            )
        case "fire_tv_open":
            return await fireTV.execute(arguments)
        case "cancel_fit_pic":
            return "The fit pic countdown was cancelled."
        case "end_conversation":
            return "Conversation ended."
        default:
            return "That tool is not installed on Wall."
        }
    }
}

private final class SonosLocalController: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var continuation: CheckedContinuation<URL?, Never>?

    private func discover() async -> URL? {
        if let saved = UserDefaults.standard.string(forKey: "wall.sonos.host"),
           let url = URL(string: "http://\(saved):1400") { return url }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.continuation = continuation
                let browser = NetServiceBrowser()
                self.browser = browser
                browser.delegate = self
                browser.searchForServices(ofType: "_sonos._tcp.", inDomain: "local.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.finishDiscovery(nil) }
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return }
        UserDefaults.standard.set(host, forKey: "wall.sonos.host")
        finishDiscovery(URL(string: "http://\(host):1400"))
    }

    private func finishDiscovery(_ result: URL?) {
        browser?.stop()
        browser = nil
        services.removeAll()
        continuation?.resume(returning: result)
        continuation = nil
    }

    func execute(_ arguments: [String: Any]) async -> String {
        guard let baseURL = await discover() else {
            return "I couldn't find a Sonos speaker on this Wi-Fi."
        }
        let action = (arguments["action"] as? String ?? "play").lowercased()
        if action == "set_volume" {
            let volume = min(100, max(0, arguments["volume"] as? Int ?? 25))
            return await soap(
                baseURL: baseURL,
                path: "/MediaRenderer/RenderingControl/Control",
                service: "urn:schemas-upnp-org:service:RenderingControl:1",
                action: "SetVolume",
                body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(volume)</DesiredVolume>"
            ) ? "Sonos volume is \(volume)." : "Sonos didn't accept the volume command."
        }
        let mapped = ["play": "Play", "pause": "Pause", "next": "Next", "previous": "Previous"][action]
        guard let command = mapped else {
            return "Local Sonos currently supports play, pause, next, previous, and volume."
        }
        let extra = command == "Play" ? "<Speed>1</Speed>" : ""
        let worked = await soap(
            baseURL: baseURL,
            path: "/MediaRenderer/AVTransport/Control",
            service: "urn:schemas-upnp-org:service:AVTransport:1",
            action: command,
            body: "<InstanceID>0</InstanceID>\(extra)"
        )
        return worked ? "Sonos \(action) command sent." : "Sonos didn't accept that command."
    }

    private func soap(baseURL: URL, path: String, service: String, action: String, body: String) async -> Bool {
        let request = SonosSOAP.makeRequest(
            baseURL: baseURL,
            path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            service: service,
            action: action,
            body: body
        )
        return (try? await SonosSOAP.validatedData(for: request, using: .shared)) != nil
    }
}

private final class FireTVController {
    func execute(_ arguments: [String: Any]) async -> String {
        let title = arguments["title"] as? String ?? "that"
        let app = arguments["app"] as? String ?? "MovieBoxPro"
        guard UserDefaults.standard.string(forKey: "wall.firetv.host") != nil else {
            return "I need the Fire TV's one-time pairing before I can open \(title) in \(app)."
        }
        return "The Fire TV is discovered, but \(app) deep-link pairing still needs to be completed."
    }
}
