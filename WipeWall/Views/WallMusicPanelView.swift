import SwiftUI

struct WallMusicSearchResult: Identifiable, Equatable {
    let reference: SpotifyTrackReference
    let trackName: String
    let artistName: String
    let collectionName: String?
    let artworkURL: URL?

    var id: String { reference.id }
    var spotifyQuery: String { "\(trackName) by \(artistName)" }
}

struct WallMusicSearchEnvelope: Decodable {
    struct Page: Decodable { let items: [Track?] }
    struct Track: Decodable {
        struct Artist: Decodable { let name: String }
        struct Album: Decodable {
            struct Image: Decodable { let url: URL }
            let name: String?
            let images: [Image]?
        }
        let id: String?
        let name: String
        let artists: [Artist]
        let album: Album?
        let type: String?
        let is_playable: Bool?

        var result: WallMusicSearchResult? {
            guard type == nil || type == "track", is_playable != false,
                  let id, let reference = SpotifyTrackResolver.reference(in: "spotify:track:\(id)"),
                  reference.id == id else { return nil }
            return WallMusicSearchResult(reference: reference, trackName: name,
                artistName: artists.map(\.name).joined(separator: ", "),
                collectionName: album?.name, artworkURL: album?.images?.first?.url)
        }
    }
    let tracks: Page
    var results: [WallMusicSearchResult] {
        var seen = Set<String>()
        return tracks.items.compactMap { $0?.result }.filter { seen.insert($0.id).inserted }
    }
}

@MainActor
final class WallMusicSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [WallMusicSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var playingID: String?
    @Published private(set) var queueingID: String?
    @Published private(set) var status = ""

    private let catalogSearch: (String) async throws -> [WallMusicSearchResult]
    private var searchTask: Task<Void, Never>?
    private var playbackStatusTask: Task<Void, Never>?

    init(catalogSearch: @escaping (String) async throws -> [WallMusicSearchResult] = {
        try await SpotifyCatalogClient.shared.searchTracks(query: $0)
    }) {
        self.catalogSearch = catalogSearch
    }

    deinit {
        searchTask?.cancel()
        playbackStatusTask?.cancel()
    }

    func scheduleSearch() {
        searchTask?.cancel()
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else {
            results = []
            isSearching = false
            status = ""
            return
        }
        isSearching = true
        results = []
        status = ""
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let rows = try await catalogSearch(searchQuery)
                guard !Task.isCancelled else { return }
                results = rows
                status = results.isEmpty ? "NO RESULTS" : ""
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                status = error.localizedDescription
            }
            isSearching = false
        }
    }

    func play(_ result: WallMusicSearchResult, nowPlaying: SonosNowPlayingService) async -> Bool {
        guard playingID == nil, queueingID == nil else { return false }
        playingID = result.id
        startPlaybackStatusAnimation()
        let message = await SonosMusicService.shared.playRadio(
            seed: result.reference,
            title: result.spotifyQuery
        )
        playbackStatusTask?.cancel()
        playbackStatusTask = nil
        if message.hasPrefix("Playing ") {
            status = "playing"
            await nowPlaying.refresh()
            playingID = nil
            return true
        } else {
            status = message
        }
        playingID = nil
        return false
    }

    func queue(_ result: WallMusicSearchResult) async {
        guard playingID == nil, queueingID == nil else { return }
        queueingID = result.id
        status = "queueing…"
        let message = await SonosMusicService.shared.queue(reference: result.reference, title: result.spotifyQuery)
        status = message.hasPrefix("Queued ") ? "queued" : message
        queueingID = nil
    }

    private func startPlaybackStatusAnimation() {
        playbackStatusTask?.cancel()
        playbackStatusTask = Task { [weak self] in
            var step = 0
            while !Task.isCancelled {
                self?.status = "playing" + String(repeating: ".", count: step % 4)
                step += 1
                try? await Task.sleep(nanoseconds: 330_000_000)
            }
        }
    }

    nonisolated static func results(in data: Data) throws -> [WallMusicSearchResult] {
        try JSONDecoder().decode(WallMusicSearchEnvelope.self, from: data).results
    }
}

enum WallSpotifySearchKind: String, CaseIterable, Identifiable {
    case song
    case album
    case playlist

    var id: String { rawValue }

    var collectionKind: SpotifyCollectionSearchKind? {
        switch self {
        case .song: return nil
        case .album: return .album
        case .playlist: return .playlist
        }
    }
}

@MainActor
final class WallSpotifyCollectionSearchModel: ObservableObject {
    @Published private(set) var results: [SonosNativePlaylist] = []
    @Published private(set) var isSearching = false
    @Published private(set) var playingID: String?
    @Published private(set) var status = ""

    private var searchTask: Task<Void, Never>?
    private var playbackStatusTask: Task<Void, Never>?

    deinit {
        searchTask?.cancel()
        playbackStatusTask?.cancel()
    }

    func scheduleSearch(query rawQuery: String, kind: SpotifyCollectionSearchKind) {
        searchTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            isSearching = false
            status = ""
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                results = try await SonosNativePlaylistService.shared.searchSpotify(query: query, kind: kind)
                status = results.isEmpty ? "NO RESULTS" : ""
            } catch {
                results = []
                status = "SPOTIFY SEARCH UNAVAILABLE"
            }
            isSearching = false
        }
    }

    func play(
        _ result: SonosNativePlaylist,
        kind: SpotifyCollectionSearchKind,
        nowPlaying: SonosNowPlayingService
    ) async -> Bool {
        guard playingID == nil else { return false }
        playingID = "\(kind.rawValue):\(result.id)"
        startPlaybackStatusAnimation()
        let message = await SonosNativePlaylistService.shared.play(result, source: .spotify)
        playbackStatusTask?.cancel()
        playbackStatusTask = nil
        if message.hasPrefix("Playing ") {
            status = "playing"
            await nowPlaying.refresh()
            playingID = nil
            return true
        }
        status = message
        playingID = nil
        return false
    }

    private func startPlaybackStatusAnimation() {
        playbackStatusTask?.cancel()
        playbackStatusTask = Task { [weak self] in
            var step = 0
            while !Task.isCancelled {
                self?.status = "playing" + String(repeating: ".", count: step % 4)
                step += 1
                try? await Task.sleep(nanoseconds: 330_000_000)
            }
        }
    }
}

@MainActor
final class WallSoundCloudSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [SoundCloudTrackResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var playingID: String?
    @Published private(set) var queueingID: String?
    @Published private(set) var status = ""

    private var searchTask: Task<Void, Never>?
    private var playbackStatusTask: Task<Void, Never>?

    deinit {
        searchTask?.cancel()
        playbackStatusTask?.cancel()
    }

    func scheduleSearch() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            results = []
            isSearching = false
            status = ""
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                results = try await SoundCloudSonosService.shared.search(query: term)
                status = results.isEmpty ? "NO RESULTS" : ""
            } catch {
                results = []
                status = ((error as? LocalizedError)?.errorDescription ?? "SoundCloud unavailable").uppercased()
            }
            isSearching = false
        }
    }

    func play(_ result: SoundCloudTrackResult, nowPlaying: SonosNowPlayingService) async -> Bool {
        guard playingID == nil, queueingID == nil else { return false }
        playingID = result.id
        startPlaybackStatusAnimation()
        let message = await SoundCloudSonosService.shared.play(result)
        playbackStatusTask?.cancel()
        playbackStatusTask = nil
        if message.hasPrefix("Playing ") {
            status = "playing"
            await nowPlaying.refresh()
            playingID = nil
            return true
        }
        status = message
        playingID = nil
        return false
    }

    func queue(_ result: SoundCloudTrackResult) async {
        guard playingID == nil, queueingID == nil else { return }
        queueingID = result.id
        status = "queueing…"
        let message = await SoundCloudSonosService.shared.queue(result)
        status = message.hasPrefix("Queued ") ? "queued" : message
        queueingID = nil
    }

    private func startPlaybackStatusAnimation() {
        playbackStatusTask?.cancel()
        playbackStatusTask = Task { [weak self] in
            var step = 0
            while !Task.isCancelled {
                self?.status = "playing" + String(repeating: ".", count: step % 4)
                step += 1
                try? await Task.sleep(nanoseconds: 330_000_000)
            }
        }
    }
}

struct WallMusicPanelView: View {
    @ObservedObject var service: SonosNowPlayingService
    let startsFocusedOnSearch: Bool

    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = WallMusicSearchModel()
    @StateObject private var spotifyCollectionSearch = WallSpotifyCollectionSearchModel()
    @StateObject private var soundcloudSearch = WallSoundCloudSearchModel()
    @ObservedObject private var spotifyAccount = SpotifyAccountService.shared
    @State private var selectedSource: WallMusicSource = .spotify
    @State private var selectedSpotifySearchKind: WallSpotifySearchKind = .song
    @State private var liveVolume = 0.0
    @State private var isDraggingVolume = false
    @State private var showingPlaylists = false
    @State private var playlists: [SiftCloudPlaylist] = []
    @State private var playlistStatus = ""
    @State private var playingPlaylistID: String?
    @State private var queue: SiftCloudQueue?
    @State private var queueStatus = ""
    @State private var playingQueueTrackID: String?
    @State private var soundcloudPlaylists: [SonosNativePlaylist] = []
    @State private var spotifyPlaylistStatus = ""
    @State private var soundcloudPlaylistStatus = ""
    @State private var playingNativePlaylistID: String?
    @AppStorage("wall.music.playlists.sift.open") private var siftPlaylistsOpen = true
    @AppStorage("wall.music.playlists.spotify.open") private var spotifyPlaylistsOpen = false
    @AppStorage("wall.music.playlists.soundcloud.open") private var soundcloudPlaylistsOpen = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black)
                }
                .buttonStyle(WallMusicPressStyle())
                .accessibilityLabel("Close music")
                .accessibilityIdentifier("wall.music.close")
            }

            nowPlaying
                .padding(.top, 4)

            browserControls
                .padding(.top, 24)

            browserResults
                .padding(.top, 8)
        }
        .padding(22)
        .background(Color.white.ignoresSafeArea())
        .onAppear {
            liveVolume = Double(service.snapshot.volume)
            service.start()
            loadQueue()
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-WallVerifySpotifySearch"), index + 1 < arguments.count {
                search.query = arguments[index + 1].lowercased()
            }
            if startsFocusedOnSearch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { searchFocused = true }
            }
        }
        .onChange(of: service.snapshot.volume) { value in
            guard !isDraggingVolume else { return }
            liveVolume = Double(value)
        }
        .onChange(of: spotifyAccount.isConnected) { connected in
            if connected { scheduleSpotifySearch() }
        }
        .onChange(of: search.query) { value in
            let lowercase = value.lowercased()
            if value != lowercase {
                search.query = lowercase
            } else {
                scheduleSpotifySearch()
            }
        }
        .onChange(of: selectedSpotifySearchKind) { _ in
            showingPlaylists = false
            scheduleSpotifySearch()
        }
        .onChange(of: soundcloudSearch.query) { value in
            let lowercase = value.lowercased()
            if value != lowercase {
                soundcloudSearch.query = lowercase
            } else {
                soundcloudSearch.scheduleSearch()
            }
        }
        .onChange(of: spotifyPlaylistsOpen) { open in
            if open { loadNativePlaylists(.spotify) }
        }
        .onChange(of: soundcloudPlaylistsOpen) { open in
            if open { loadNativePlaylists(.soundcloud) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    scheduleActiveSearch()
                    searchFocused = false
                }
                .font(.custom("Helvetica-Bold", size: 15))
            }
        }
    }

    private var nowPlaying: some View {
        HStack(alignment: .center, spacing: 22) {
            albumArtwork
                .frame(width: 176, height: 176)

            VStack(alignment: .leading, spacing: 12) {
                Text(service.snapshot.title)
                    .font(.custom("Helvetica-Bold", size: 34))
                    .foregroundColor(.black)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                Text([service.snapshot.artist, service.snapshot.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.custom("Helvetica", size: 15))
                    .foregroundColor(.black.opacity(0.62))
                    .lineLimit(2)

                HStack(spacing: 12) {
                    mediaButton(symbol: "backward.end.fill", label: "Previous", action: service.skipBackward)
                    mediaButton(
                        symbol: service.snapshot.isPlaying ? "pause.fill" : "play.fill",
                        label: service.snapshot.isPlaying ? "Pause" : "Play",
                        action: service.togglePlayPause
                    )
                    mediaButton(symbol: "forward.end.fill", label: "Next", action: service.skipForward)
                    mediaButton(
                        symbol: "shuffle",
                        label: service.isShuffleEnabled ? "Turn shuffle off" : "Shuffle",
                        isSelected: service.isShuffleEnabled,
                        action: service.toggleShuffle
                    )
                }

                HStack(spacing: 10) {
                    Image(systemName: volumeSymbol)
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 20)
                    WallVolumeSlider(
                        value: $liveVolume,
                        isEnabled: service.connectionState == .connected,
                        onEditingChanged: { isDraggingVolume = $0 },
                        onValueChanged: { service.setVolume(Int($0.rounded())) }
                    )
                    Text("\(Int(liveVolume.rounded()))")
                        .font(.custom("Helvetica-Bold", size: 12))
                        .monospacedDigit()
                        .frame(width: 26, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var albumArtwork: some View {
        if let url = service.snapshot.albumArtURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    artworkPlaceholder
                }
            }
            .clipped()
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Color.black
            Image(systemName: "music.note")
                .font(.system(size: 54, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var browserControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                sourceButton(.spotify)
                sourceButton(.soundcloud)
            }
            .frame(height: 34)

            if selectedSource == .spotify {
                HStack(spacing: 0) {
                    ForEach(WallSpotifySearchKind.allCases) { kind in
                        spotifySearchKindButton(kind)
                    }
                }
                .frame(height: 34)
            }

            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width - 10)
                HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .bold))
                    TextField(activeSearchPlaceholder, text: activeQuery)
                        .font(.custom("Helvetica-Bold", size: 17))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .focused($searchFocused)
                        .onSubmit {
                            scheduleActiveSearch()
                            searchFocused = false
                        }
                    if activeSearchIsRunning {
                        ProgressView().progressViewStyle(.circular)
                    }
                }
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .frame(width: availableWidth * 0.75, height: 48)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
                .onTapGesture { showingPlaylists = false }

                Button {
                    selectedSource = .spotify
                    showingPlaylists = true
                    searchFocused = false
                    loadPlaylists()
                    if spotifyPlaylistsOpen { loadNativePlaylists(.spotify) }
                    if soundcloudPlaylistsOpen { loadNativePlaylists(.soundcloud) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note.list")
                        Text("playlists")
                            .font(.custom("Helvetica-Bold", size: 15))
                    }
                    .foregroundColor(showingPlaylists ? .white : .black)
                    .frame(width: availableWidth * 0.25, height: 48)
                    .background(showingPlaylists ? Color.black : Color.white)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
                }
                .buttonStyle(WallMusicPressStyle())
                .accessibilityIdentifier("wall.music.playlists")
                }
            }
            .frame(height: 48)
        }
        .frame(height: selectedSource == .spotify ? 132 : 90)
    }

    @ViewBuilder
    private var browserResults: some View {
        if selectedSource == .soundcloud {
            soundcloudResults
        } else if showingPlaylists {
            playlistResults
        } else if selectedSpotifySearchKind == .song,
                  search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queueResults
        } else if selectedSpotifySearchKind == .song {
            searchResults
        } else {
            spotifyCollectionResults
        }
    }

    private var activeQuery: Binding<String> {
        selectedSource == .spotify ? $search.query : $soundcloudSearch.query
    }

    private var activeSearchPlaceholder: String {
        guard selectedSource == .spotify else { return "search soundcloud" }
        return "search spotify \(selectedSpotifySearchKind.rawValue)s"
    }

    private var activeSearchIsRunning: Bool {
        guard selectedSource == .spotify else { return soundcloudSearch.isSearching }
        return selectedSpotifySearchKind == .song ? search.isSearching : spotifyCollectionSearch.isSearching
    }

    private func scheduleActiveSearch() {
        if selectedSource == .spotify {
            scheduleSpotifySearch()
        } else {
            soundcloudSearch.scheduleSearch()
        }
    }

    private func scheduleSpotifySearch() {
        if let kind = selectedSpotifySearchKind.collectionKind {
            spotifyCollectionSearch.scheduleSearch(query: search.query, kind: kind)
        } else {
            search.scheduleSearch()
        }
    }

    private func spotifySearchKindButton(_ kind: WallSpotifySearchKind) -> some View {
        Button {
            selectedSpotifySearchKind = kind
            searchFocused = false
        } label: {
            Text(kind.rawValue)
                .font(.custom("Helvetica-Bold", size: 12))
                .foregroundColor(selectedSpotifySearchKind == kind ? .white : .black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selectedSpotifySearchKind == kind ? Color.black : Color.white)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 1.5))
        }
        .buttonStyle(WallMusicPressStyle())
        .accessibilityIdentifier("wall.music.spotify.search-kind.\(kind.rawValue)")
    }

    private func sourceButton(_ source: WallMusicSource) -> some View {
        Button {
            selectedSource = source
            showingPlaylists = false
            searchFocused = false
        } label: {
            Text(source.rawValue)
                .font(.custom("Helvetica-Bold", size: 13))
                .foregroundColor(selectedSource == source ? .white : .black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selectedSource == source ? Color.black : Color.white)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
        }
        .buttonStyle(WallMusicPressStyle())
        .accessibilityIdentifier("wall.music.source.\(source.rawValue)")
    }

    private var soundcloudResults: some View {
        VStack(spacing: 0) {
            if soundcloudSearch.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("SEARCH SOUNDCLOUD")
                    .font(.custom("Helvetica-Bold", size: 11))
                    .foregroundColor(.black.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
            } else if !soundcloudSearch.status.isEmpty {
                Text(soundcloudSearch.status)
                    .font(.custom("Helvetica-Bold", size: 11))
                    .foregroundColor(.black.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(soundcloudSearch.results) { result in
                        HStack(spacing: 0) {
                            Button {
                                Task {
                                    if await soundcloudSearch.play(result, nowPlaying: service) {
                                        dismiss()
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    AsyncImage(url: result.artworkURL) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Color.black
                                        }
                                    }
                                    .frame(width: 28, height: 28)
                                    .clipped()

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(result.title)
                                            .font(.custom("Helvetica-Bold", size: 11.5))
                                        Text([result.artist, result.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.custom("Helvetica", size: 9))
                                            .foregroundColor(.black.opacity(0.58))
                                    }
                                    .foregroundColor(.black)
                                    .lineLimit(1)
                                    Spacer()
                                    if soundcloudSearch.playingID == result.id {
                                        ProgressView().progressViewStyle(.circular)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(WallMusicPressStyle())
                            .disabled(soundcloudSearch.playingID != nil || soundcloudSearch.queueingID != nil)

                            queueButton(
                                isLoading: soundcloudSearch.queueingID == result.id,
                                label: "Queue \(result.title)"
                            ) {
                                Task { await soundcloudSearch.queue(result) }
                            }
                            .disabled(soundcloudSearch.playingID != nil || soundcloudSearch.queueingID != nil)
                        }
                        .frame(height: 36)

                        Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1)
                    }
                }
            }
        }
    }

    private var queueResults: some View {
        VStack(spacing: 0) {
            Text(queueStatus.isEmpty ? "QUEUE" : queueStatus)
                .font(.custom("Helvetica-Bold", size: 11))
                .foregroundColor(.black.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue?.tracks ?? [], id: \.id) { track in
                        Button {
                            playQueueTrack(track)
                        } label: {
                            HStack(spacing: 8) {
                                AsyncImage(url: SiftSonosService.shared.artworkURL(for: track)) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        ZStack {
                                            Color.black
                                            Image(systemName: "music.note")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                                .frame(width: 28, height: 28)
                                .clipped()

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title)
                                        .font(.custom("Helvetica-Bold", size: 11.5))
                                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.custom("Helvetica", size: 9))
                                        .foregroundColor(.black.opacity(0.58))
                                }
                                .foregroundColor(.black)
                                .lineLimit(1)

                                Spacer()
                                if playingQueueTrackID == track.id {
                                    ProgressView().progressViewStyle(.circular)
                                }
                            }
                            .frame(height: 36)
                        }
                        .buttonStyle(WallMusicPressStyle())
                        .disabled(playingQueueTrackID != nil)

                        Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1)
                    }
                }
            }
        }
    }

    private var searchResults: some View {
        VStack(spacing: 0) {
            if !search.status.isEmpty {
                Text(search.status)
                    .font(.custom("Helvetica-Bold", size: 11))
                    .foregroundColor(.black.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(search.results) { result in
                        HStack(spacing: 0) {
                            Button {
                                Task {
                                    if await search.play(result, nowPlaying: service) {
                                        dismiss()
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    AsyncImage(url: result.artworkURL) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Color.black
                                        }
                                    }
                                    .frame(width: 28, height: 28)
                                    .clipped()

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(result.trackName)
                                            .font(.custom("Helvetica-Bold", size: 11.5))
                                        Text([result.artistName, result.collectionName ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.custom("Helvetica", size: 9))
                                            .foregroundColor(.black.opacity(0.58))
                                    }
                                    .foregroundColor(.black)
                                    .lineLimit(1)
                                    Spacer()
                                    if search.playingID == result.id {
                                        ProgressView().progressViewStyle(.circular)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(WallMusicPressStyle())
                            .disabled(search.playingID != nil || search.queueingID != nil)

                            queueButton(
                                isLoading: search.queueingID == result.id,
                                label: "Queue \(result.trackName)"
                            ) {
                                Task { await search.queue(result) }
                            }
                            .disabled(search.playingID != nil || search.queueingID != nil)
                        }
                        .frame(height: 36)

                        Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1)
                    }
                }
            }
        }
    }

    private var spotifyCollectionResults: some View {
        VStack(spacing: 0) {
            let trimmedQuery = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = selectedSpotifySearchKind.collectionKind
            let header = trimmedQuery.isEmpty
                ? "SEARCH SPOTIFY \(selectedSpotifySearchKind.rawValue.uppercased())S"
                : spotifyCollectionSearch.status

            if !header.isEmpty {
                Text(header)
                    .font(.custom("Helvetica-Bold", size: 11))
                    .foregroundColor(.black.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(spotifyCollectionSearch.results) { result in
                        Button {
                            guard let kind else { return }
                            Task {
                                if await spotifyCollectionSearch.play(result, kind: kind, nowPlaying: service) {
                                    dismiss()
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                AsyncImage(url: result.artworkURL) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        ZStack {
                                            Color.black
                                            Image(systemName: selectedSpotifySearchKind == .album ? "square.stack" : "music.note.list")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                                .frame(width: 28, height: 28)
                                .clipped()

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.title)
                                        .font(.custom("Helvetica-Bold", size: 11.5))
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.custom("Helvetica", size: 9))
                                            .foregroundColor(.black.opacity(0.58))
                                    }
                                }
                                .foregroundColor(.black)
                                .lineLimit(1)

                                Spacer()
                                if spotifyCollectionSearch.playingID == "\(selectedSpotifySearchKind.rawValue):\(result.id)" {
                                    ProgressView().progressViewStyle(.circular)
                                }
                            }
                            .frame(height: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(WallMusicPressStyle())
                        .disabled(spotifyCollectionSearch.playingID != nil)
                        .accessibilityLabel("Play Spotify \(selectedSpotifySearchKind.rawValue) \(result.title)")

                        Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1)
                    }
                }
            }
        }
    }

    private func queueButton(
        isLoading: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(Color.black)
            .contentShape(Rectangle())
        }
        .buttonStyle(WallMusicPressStyle())
        .accessibilityLabel(label)
    }

    private var playlistResults: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                playlistSectionHeader("sift", isOpen: $siftPlaylistsOpen)
                if siftPlaylistsOpen {
                    if !playlistStatus.isEmpty {
                        playlistStatusRow(playlistStatus)
                    }
                    ForEach(playlists, id: \.id) { playlist in
                        Button {
                            play(playlist)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.black)

                                Text(playlist.name)
                                    .font(.custom("Helvetica-Bold", size: 11.5))
                                    .foregroundColor(.black)
                                    .lineLimit(1)

                                Spacer()

                                Text("\(playlist.trackIds.count)")
                                    .font(.custom("Helvetica", size: 9))
                                    .foregroundColor(.black.opacity(0.55))

                                if playingPlaylistID == playlist.id {
                                    ProgressView().progressViewStyle(.circular)
                                } else {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Color.black)
                            }
                            }
                            .frame(height: 36)
                        }
                        .buttonStyle(WallMusicPressStyle())
                        .disabled(playingPlaylistID != nil)

                        Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1)
                    }
                }

                playlistSectionHeader("spotify", isOpen: $spotifyPlaylistsOpen)
                if spotifyPlaylistsOpen {
                    if !spotifyPlaylistStatus.isEmpty { playlistStatusRow(spotifyPlaylistStatus) }
                    spotifyAccountPlaylistRows
                }

                playlistSectionHeader("soundcloud", isOpen: $soundcloudPlaylistsOpen)
                if soundcloudPlaylistsOpen {
                    if !soundcloudPlaylistStatus.isEmpty { playlistStatusRow(soundcloudPlaylistStatus) }
                    nativePlaylistRows(soundcloudPlaylists, source: .soundcloud)
                }
            }
        }
    }

    private func playlistSectionHeader(_ title: String, isOpen: Binding<Bool>) -> some View {
        Button {
            isOpen.wrappedValue.toggle()
        } label: {
            HStack {
                Text(title)
                    .font(.custom("Helvetica-Bold", size: 15))
                Spacer()
                Image(systemName: isOpen.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(Color.black, lineWidth: 1.5))
        }
        .buttonStyle(WallMusicPressStyle())
        .accessibilityIdentifier("wall.music.playlists.\(title).toggle")
    }

    private func playlistStatusRow(_ value: String) -> some View {
        Text(value)
            .font(.custom("Helvetica-Bold", size: 10))
            .foregroundColor(.black.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 36)
    }

    private func nativePlaylistRows(_ values: [SonosNativePlaylist], source: WallMusicSource) -> some View {
        ForEach(values) { playlist in
            Button {
                playNativePlaylist(playlist, source: source)
            } label: {
                HStack(spacing: 8) {
                    AsyncImage(url: playlist.artworkURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.black
                        }
                    }
                    .frame(width: 28, height: 28)
                    .clipped()

                    Text(playlist.title)
                        .font(.custom("Helvetica-Bold", size: 11.5))
                        .foregroundColor(.black)
                        .lineLimit(1)
                    Spacer()
                    if playingNativePlaylistID == "\(source.rawValue):\(playlist.id)" {
                        ProgressView().progressViewStyle(.circular)
                    } else {
                        Text(source.rawValue)
                            .font(.custom("Helvetica-Bold", size: 8))
                            .foregroundColor(.black.opacity(0.45))
                    }
                }
                .frame(height: 36)
            }
            .buttonStyle(WallMusicPressStyle())
            .disabled(playingNativePlaylistID != nil)

            Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1)
        }
    }

    private var spotifyAccountPlaylistRows: some View {
        ForEach(spotifyAccount.playlists) { playlist in
            Button {
                playSpotifyAccountPlaylist(playlist)
            } label: {
                HStack(spacing: 8) {
                    AsyncImage(url: playlist.artworkURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            ZStack {
                                Color.black
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .frame(width: 28, height: 28)
                    .clipped()

                    VStack(alignment: .leading, spacing: 1) {
                        Text(playlist.name)
                            .font(.custom("Helvetica-Bold", size: 11.5))
                        Text([playlist.ownerName, playlist.trackCount > 0 ? "\(playlist.trackCount) tracks" : ""]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(.custom("Helvetica", size: 9))
                            .foregroundColor(.black.opacity(0.55))
                    }
                    .foregroundColor(.black)
                    .lineLimit(1)

                    Spacer()
                    if playingNativePlaylistID == "spotify:\(playlist.id)" {
                        ProgressView().progressViewStyle(.circular)
                    } else {
                        Text("spotify")
                            .font(.custom("Helvetica-Bold", size: 8))
                            .foregroundColor(.black.opacity(0.45))
                    }
                }
                .frame(height: 36)
            }
            .buttonStyle(WallMusicPressStyle())
            .disabled(playingNativePlaylistID != nil || spotifyAccount.isWorking)

            Rectangle().fill(Color.black.opacity(0.13)).frame(height: 1)
        }
    }

    private func loadNativePlaylists(_ source: WallMusicSource) {
        if source == .spotify {
            guard spotifyAccount.playlists.isEmpty else {
                spotifyPlaylistStatus = ""
                return
            }
            spotifyPlaylistStatus = "LOADING SPOTIFY…"
            Task {
                await spotifyAccount.restore()
                if spotifyAccount.isConnected, spotifyAccount.playlists.isEmpty {
                    await spotifyAccount.loadPlaylists()
                }
                if spotifyAccount.isConnected {
                    spotifyPlaylistStatus = spotifyAccount.playlists.isEmpty ? "NO SPOTIFY PLAYLISTS" : ""
                } else {
                    spotifyPlaylistStatus = "CONNECT SPOTIFY IN SETTINGS"
                }
            }
            return
        } else {
            guard soundcloudPlaylists.isEmpty else { return }
            soundcloudPlaylistStatus = "LOADING SOUNDCLOUD…"
        }
        Task {
            do {
                let rows = try await SonosNativePlaylistService.shared.playlists(for: source)
                soundcloudPlaylists = rows
                soundcloudPlaylistStatus = rows.isEmpty ? "NO SOUNDCLOUD PLAYLISTS" : ""
            } catch {
                let message = ((error as? LocalizedError)?.errorDescription ?? "Sonos unavailable").uppercased()
                soundcloudPlaylistStatus = message
            }
        }
    }

    private func playSpotifyAccountPlaylist(_ playlist: SpotifyUserPlaylist) {
        guard playingNativePlaylistID == nil else { return }
        playingNativePlaylistID = "spotify:\(playlist.id)"
        spotifyPlaylistStatus = "PLAYING…"
        Task {
            let played = await spotifyAccount.play(playlist)
            playingNativePlaylistID = nil
            await service.refresh()
            if played {
                dismiss()
            } else {
                spotifyPlaylistStatus = spotifyAccount.status.uppercased()
            }
        }
    }

    private func playNativePlaylist(_ playlist: SonosNativePlaylist, source: WallMusicSource) {
        guard playingNativePlaylistID == nil else { return }
        playingNativePlaylistID = "\(source.rawValue):\(playlist.id)"
        if source == .spotify {
            spotifyPlaylistStatus = "PLAYING…"
        } else {
            soundcloudPlaylistStatus = "PLAYING…"
        }
        Task {
            let message = await SonosNativePlaylistService.shared.play(playlist, source: source)
            playingNativePlaylistID = nil
            await service.refresh()
            if message.hasPrefix("Playing ") {
                dismiss()
            } else if source == .spotify {
                spotifyPlaylistStatus = message.uppercased()
            } else {
                soundcloudPlaylistStatus = message.uppercased()
            }
        }
    }

    private func loadPlaylists() {
        playlistStatus = playlists.isEmpty ? "LOADING PLAYLISTS…" : ""
        Task {
            do {
                playlists = try await SiftSonosService.shared.availablePlaylists()
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                playlistStatus = playlists.isEmpty ? "NO PLAYLISTS" : ""
            } catch {
                playlistStatus = "PLAYLISTS UNAVAILABLE"
            }
        }
    }

    private func loadQueue() {
        queueStatus = queue == nil ? "LOADING QUEUE…" : ""
        Task {
            do {
                queue = try await SiftSonosService.shared.availableQueue()
                queueStatus = queue?.tracks.isEmpty == false ? "" : "QUEUE IS EMPTY"
            } catch {
                queueStatus = "QUEUE UNAVAILABLE"
            }
        }
    }

    private func playQueueTrack(_ track: SiftCloudTrack) {
        guard playingQueueTrackID == nil else { return }
        playingQueueTrackID = track.id
        queueStatus = "PLAYING…"
        Task {
            let message = await SiftSonosService.shared.play(
                playlist: queue?.playlist.name ?? "queue",
                shuffle: false,
                startingAtTrackID: track.id
            )
            playingQueueTrackID = nil
            queueStatus = message.hasPrefix("Playing ") ? "" : message.uppercased()
            await service.refresh()
            if message.hasPrefix("Playing ") { dismiss() }
        }
    }

    private func play(_ playlist: SiftCloudPlaylist) {
        guard playingPlaylistID == nil else { return }
        playingPlaylistID = playlist.id
        playlistStatus = "STARTING \(playlist.name.uppercased())…"
        Task {
            let message = await SiftSonosService.shared.play(playlist: playlist.name, shuffle: false)
            playlistStatus = message.uppercased()
            playingPlaylistID = nil
            await service.refresh()
            if message.hasPrefix("Playing ") { dismiss() }
        }
    }

    private func mediaButton(
        symbol: String,
        label: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(isSelected ? .black : .white)
                .frame(width: 48, height: 48)
                .background(isSelected ? Color.white : Color.black)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
        }
        .buttonStyle(WallMusicPressStyle())
        .accessibilityLabel(label)
    }

    private var volumeSymbol: String {
        switch liveVolume {
        case ..<1: return "speaker.slash.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

private struct WallMusicPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
