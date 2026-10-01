import SwiftUI

struct WallSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var voice: DonVoiceController
    @ObservedObject private var sift = SiftSonosService.shared
    @ObservedObject private var spotify = SpotifyAccountService.shared
    @AppStorage("don.bridge.url") private var bridgeURL = ""
    @State private var siftUsername = ""
    @State private var siftPassword = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Voice") {
                    Toggle("Listen for Wall wake phrases", isOn: $voice.wakeWordEnabled)
                        .accessibilityIdentifier("wall.settings.wake-toggle")
                        .onChange(of: voice.wakeWordEnabled) { _ in
                            voice.reloadConfiguration()
                        }
                    Text(voice.wakeStatus)
                        .font(.custom("Helvetica", size: 14))
                        .foregroundColor(.secondary)
                    if let error = voice.lastVoiceError {
                        Text(error)
                            .font(.custom("Helvetica", size: 14))
                            .foregroundColor(.primary)
                    }
                    if !voice.lastWakeTranscript.isEmpty {
                        Text("Last heard: \(voice.lastWakeTranscript)")
                            .font(.custom("Helvetica", size: 14))
                            .foregroundColor(.secondary)
                    }
                    TextField("Optional voice bridge URL", text: $bridgeURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                Section {
                    Text("Say “Hi Wall,” “Hey Wall,” “Yo Wall,” or “Wally” to start voice mode.")
                        .font(.custom("Helvetica", size: 14))
                        .foregroundColor(.secondary)
                }
                Section("Sift + Sonos") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sift.isConnected ? "Private Sift connected" : "Private Sift unavailable")
                            Text("Use your own Sift account")
                                .font(.custom("Helvetica", size: 13))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if sift.isWorking {
                            ProgressView()
                        } else {
                            Button("Check") { Task { await sift.verifyConnection() } }
                        }
                    }
                    Text(sift.status)
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(.secondary)
                    if !sift.isConnected {
                        TextField("Sift username", text: $siftUsername)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        SecureField("Sift password", text: $siftPassword)
                        Button("Connect Sift") {
                            Task {
                                await sift.connect(username: siftUsername, password: siftPassword)
                                siftPassword = ""
                            }
                        }
                        .disabled(sift.isWorking || siftUsername.isEmpty || siftPassword.isEmpty)
                    } else {
                        Button("Disconnect Sift") { sift.disconnect() }
                    }
                    Text("Configure your own Sift server before building. Your login enrolls this iPad; no service credential ships in the app.")
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(.secondary)
                }
                Section("Spotify") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(spotify.isConnected ? "Spotify connected" : "Spotify not connected")
                            if !spotify.displayName.isEmpty {
                                Text(spotify.displayName)
                                    .font(.custom("Helvetica", size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if spotify.isWorking {
                            ProgressView()
                        } else if spotify.isConnected {
                            Button("Disconnect") { spotify.disconnect() }
                                .accessibilityIdentifier("wall.settings.spotify.disconnect")
                        } else {
                            Button("Connect") { spotify.connect() }
                                .accessibilityIdentifier("wall.settings.spotify.connect")
                        }
                    }
                    Text(spotify.status)
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(.secondary)
                    Text("Wall reads your private and collaborative playlists. Spotify authorization stays in this iPad’s Keychain.")
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityIdentifier("wall.settings.view")
            .font(.custom("Helvetica", size: 17))
            .navigationTitle("Wall")
            .task {
                async let siftCheck: Void = sift.verifyConnection()
                async let spotifyRestore: Void = spotify.restore()
                _ = await (siftCheck, spotifyRestore)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    InstantActionButton(action: {
                        dismiss()
                    }) {
                        Text("Done")
                    }
                    .accessibilityIdentifier("wall.settings.done")
                }
            }
        }
    }
}
