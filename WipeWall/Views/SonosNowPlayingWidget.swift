import SwiftUI

/// Always-present Sonos surface. The canvas should own the service with
/// @StateObject, then place this view inside its standard MovableWallElement.
struct SonosNowPlayingWidget: View {
    static let preferredSize = CGSize(width: 560, height: 132)

    @ObservedObject var service: SonosNowPlayingService
    let onOpen: () -> Void
    let onSearch: () -> Void
    var onVolumeInteractionChanged: (Bool) -> Void = { _ in }
    @State private var liveVolume = 0.0
    @State private var isDraggingVolume = false

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Button(action: onOpen) {
                albumArtwork
                    .frame(width: 106, height: 106)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SonosPressStyle())
            .accessibilityLabel("Open music")
            .accessibilityIdentifier("wall.sonos.artwork")

            VStack(alignment: .leading, spacing: 9) {
                nowPlaying
                controls
            }
        }
        .padding(13)
        .onAppear {
            liveVolume = Double(service.snapshot.volume)
            service.start()
        }
        .onDisappear { service.stop() }
        .onChange(of: service.snapshot.volume) { value in
            guard !isDraggingVolume else { return }
            liveVolume = Double(value)
        }
        .accessibilityElement(children: .contain)
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
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var nowPlaying: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.snapshot.title)
                            .font(.custom("Helvetica-Bold", size: 22))
                            .foregroundColor(.black)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Text(byline)
                            .font(.custom("Helvetica", size: 12))
                            .foregroundColor(.black.opacity(0.58))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SonosPressStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Open music")
            .accessibilityIdentifier("wall.sonos.title")

            if case .unavailable = service.connectionState {
                Button("RETRY") { service.retryDiscovery() }
                    .font(.custom("Helvetica-Bold", size: 10))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.black)
                    .buttonStyle(SonosPressStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 9) {
            Group {
                sonosButton(
                    symbol: "backward.end.fill",
                    label: "Previous Sonos track",
                    action: service.skipBackward
                )

                sonosButton(
                    symbol: service.snapshot.isPlaying ? "pause.fill" : "play.fill",
                    label: service.snapshot.isPlaying ? "Pause Sonos" : "Play Sonos",
                    action: service.togglePlayPause
                )

                sonosButton(
                    symbol: "forward.end.fill",
                    label: "Skip Sonos track",
                    action: service.skipForward
                )

                sonosButton(
                    symbol: "shuffle",
                    label: service.isShuffleEnabled ? "Turn shuffle off" : "Shuffle Sonos queue",
                    isSelected: service.isShuffleEnabled,
                    action: service.toggleShuffle
                )

                Image(systemName: volumeSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 17)

                WallVolumeSlider(
                    value: $liveVolume,
                    isEnabled: isConnected,
                    onEditingChanged: { editing in
                        isDraggingVolume = editing
                        onVolumeInteractionChanged(editing)
                    },
                    onValueChanged: { value in service.setVolume(Int(value.rounded())) }
                )
                .accessibilityLabel("Sonos volume")
                .accessibilityValue("\(Int(liveVolume.rounded())) percent")

                Text("\(Int(liveVolume.rounded()))")
                    .font(.custom("Helvetica-Bold", size: 11))
                    .monospacedDigit()
                    .foregroundColor(.black)
                    .frame(width: 23, alignment: .trailing)
            }
            .disabled(!isConnected)
            .opacity(isConnected ? 1 : 0.35)

            sonosButton(
                symbol: "magnifyingglass",
                label: "Open music",
                action: onSearch
            )
            .accessibilityIdentifier("wall.sonos.search")
        }
    }

    private func sonosButton(
        symbol: String,
        label: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isSelected ? .black : .white)
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.white : Color.black)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(SonosPressStyle())
        .accessibilityLabel(label)
    }

    private var isConnected: Bool {
        service.connectionState == .connected
    }

    private var byline: String {
        let pieces = [service.snapshot.artist, service.snapshot.album].filter { !$0.isEmpty }
        if !pieces.isEmpty { return pieces.joined(separator: " · ") }
        switch service.snapshot.transportState {
        case .paused: return "paused"
        case .playing: return "playing"
        case .transitioning: return "loading…"
        default:
            if case let .unavailable(message) = service.connectionState { return message.lowercased() }
            return service.snapshot.speakerName
        }
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

struct WallVolumeSlider: View {
    @Binding var value: Double
    let isEnabled: Bool
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = min(max(value / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.16))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.black)
                    .frame(width: max(4, width * progress), height: 4)
                Circle()
                    .fill(Color.black)
                    .frame(width: 18, height: 18)
                    .offset(x: max(0, min(width - 18, width * progress - 9)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        onEditingChanged(true)
                        let next = min(max(Double(gesture.location.x / width) * 100, 0), 100)
                        value = next
                        onValueChanged(next)
                    }
                    .onEnded { gesture in
                        guard isEnabled else { return }
                        let next = min(max(Double(gesture.location.x / width) * 100, 0), 100)
                        value = next
                        onValueChanged(next)
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 36)
        .allowsHitTesting(isEnabled)
    }
}

private struct SonosPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
