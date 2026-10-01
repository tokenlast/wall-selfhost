import Foundation

private struct WallSonosCommandEnvelope: Decodable {
    let commands: [WallSonosCommand]
}

private struct WallSonosCommand: Decodable {
    let id: String
    let action: String
    let value: Int?
    let reference: String?
    let title: String?
}

@MainActor
final class WallSonosRemoteRelay: ObservableObject {
    private let baseURL = WallConfiguration.serverURL
    private let defaults = UserDefaults.standard
    private var pollingTask: Task<Void, Never>?
    private weak var sonos: SonosNowPlayingService?
    private var processedIDs: Set<String>

    init() {
        processedIDs = Set(UserDefaults.standard.stringArray(forKey: "wall.sonos.remote.processed.v1") ?? [])
    }

    func start(sonos: SonosNowPlayingService) {
        self.sonos = sonos
        sonos.start()
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll() async {
        guard let sonos else { return }
        do {
            let envelope: WallSonosCommandEnvelope = try await request(path: "api/device/sonos/commands")
            for command in envelope.commands where !processedIDs.contains(command.id) {
                let result = await execute(command, sonos: sonos)
                remember(command.id)
                try? await acknowledge(command.id, ok: result.ok, message: result.message)
            }
            await sonos.refresh()
            try? await upload(snapshot: sonos.snapshot, shuffle: sonos.isShuffleEnabled)
        } catch {
            // The local widget stays authoritative while Joan or the internet is unavailable.
        }
    }

    private func execute(
        _ command: WallSonosCommand,
        sonos: SonosNowPlayingService
    ) async -> (ok: Bool, message: String) {
        switch command.action {
        case "previous": sonos.skipBackward()
        case "play_pause": sonos.togglePlayPause()
        case "next": sonos.skipForward()
        case "shuffle": sonos.toggleShuffle()
        case "volume":
            guard let value = command.value else { return (false, "Missing volume") }
            sonos.setVolume(value)
        case "spotify_radio", "spotify_queue":
            guard let rawReference = command.reference,
                  let reference = SpotifyTrackResolver.reference(in: rawReference) else {
                return (false, "Invalid Spotify track")
            }
            let title = command.title ?? "Spotify"
            let message: String
            if command.action == "spotify_radio" {
                message = await SonosMusicService.shared.playRadio(seed: reference, title: title)
            } else {
                message = await SonosMusicService.shared.queue(reference: reference, title: title)
            }
            await sonos.refresh()
            return (!message.hasPrefix("I couldn’t"), message)
        case "soundcloud_play", "soundcloud_queue":
            guard let title = command.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return (false, "Invalid SoundCloud track")
            }
            let message: String
            if command.action == "soundcloud_play" {
                message = await SoundCloudSonosService.shared.play(query: title)
            } else {
                message = await SoundCloudSonosService.shared.queue(query: title)
            }
            await sonos.refresh()
            return (!message.hasPrefix("I couldn’t"), message)
        default:
            return (false, "Unsupported command")
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        await sonos.refresh()
        return (true, "done")
    }

    private func remember(_ identifier: String) {
        processedIDs.insert(identifier)
        let newest = Array(processedIDs.suffix(100))
        processedIDs = Set(newest)
        defaults.set(newest, forKey: "wall.sonos.remote.processed.v1")
    }

    private func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(KeychainToken.getOrCreate())", forHTTPHeaderField: "Authorization")
        request.setValue("Wall iPad", forHTTPHeaderField: "X-Wall-Device")
        return request
    }

    private func request<Response: Decodable>(path: String) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: authorizedRequest(path: path))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func acknowledge(_ identifier: String, ok: Bool, message: String) async throws {
        var request = authorizedRequest(path: "api/device/sonos/commands/\(identifier)", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ok": ok, "message": message])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }

    private func upload(snapshot: SonosNowPlayingSnapshot, shuffle: Bool) async throws {
        var request = authorizedRequest(path: "api/device/sonos/state", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": snapshot.title, "artist": snapshot.artist, "album": snapshot.album,
            "speaker": snapshot.speakerName, "isPlaying": snapshot.isPlaying,
            "isShuffleEnabled": shuffle, "volume": snapshot.volume,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }
}
