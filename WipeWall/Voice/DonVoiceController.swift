import AVFoundation
import Foundation
import UIKit

func initialRetardCounterValue(defaults: UserDefaults, arguments: [String]) -> Int {
    let key = "wall.retardCounter.count.v1"
    if let flagIndex = arguments.firstIndex(of: "-SetRetardCount"),
       arguments.indices.contains(flagIndex + 1),
       let requestedValue = Int(arguments[flagIndex + 1]) {
        let value = max(0, requestedValue)
        defaults.set(value, forKey: key)
        return value
    }
    return max(0, defaults.integer(forKey: key))
}

@MainActor
final class DonVoiceController: ObservableObject {
    enum State: Equatable { case sleeping, listening, thinking, speaking, unavailable }

    @Published var state: State = .sleeping
    @Published var caption = ""
    @Published private(set) var wakeStatus = "Voice listener is starting"
    @Published private(set) var lastVoiceError: String?
    @Published private(set) var lastWakeTranscript = ""
    @Published private(set) var retardCount: Int
    @Published var wakeWordEnabled: Bool {
        didSet { UserDefaults.standard.set(wakeWordEnabled, forKey: "don.wake.enabled") }
    }
    var onCancel: (() -> Void)?

    private let wakeListener = WakeWordListener()
    private let activationHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var realtime: RealtimeClient?
    private var hideTask: Task<Void, Never>?
    private var activationPlayer: AVAudioPlayer?

    init() {
        let defaults = UserDefaults.standard
        retardCount = initialRetardCounterValue(
            defaults: defaults,
            arguments: ProcessInfo.processInfo.arguments
        )
        let repairKey = "wall.voice.wakeRepair.v20"
        if !defaults.bool(forKey: repairKey) {
            // This update repairs a listener that appeared permanently broken on the
            // live iPad. Re-enable it once so the fixed listener actually gets tried.
            wakeWordEnabled = true
            defaults.set(true, forKey: "don.wake.enabled")
            defaults.set(true, forKey: repairKey)
        } else {
            wakeWordEnabled = defaults.object(forKey: "don.wake.enabled") as? Bool ?? true
        }
        activationHaptic.prepare()
        wakeListener.onWake = { [weak self] transcript in
            Task { @MainActor in self?.handleWake(transcript: transcript) }
        }
        wakeListener.onWakeDetected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.playActivationFeedback()
                self.state = .listening
                self.caption = ""
                self.wakeStatus = "Wake phrase heard"
            }
        }
        wakeListener.onCancel = { [weak self] in
            Task { @MainActor in self?.onCancel?() }
        }
        wakeListener.onAvailabilityChange = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.realtime == nil else { return }
                self.state = .sleeping
            }
        }
        wakeListener.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self, self.realtime == nil else { return }
                self.wakeStatus = status
            }
        }
        wakeListener.onTranscriptChange = { [weak self] transcript in
            Task { @MainActor in
                guard let self, self.realtime == nil else { return }
                self.lastWakeTranscript = transcript
            }
        }
        wakeListener.onTrackedWordsDetected = { [weak self] amount in
            Task { @MainActor in
                guard let self, amount > 0 else { return }
                self.retardCount = min(Int.max - amount, self.retardCount) + amount
                defaults.set(self.retardCount, forKey: "wall.retardCounter.count.v1")
            }
        }
    }

    func reloadConfiguration() {
        if wakeWordEnabled {
            startWakeWordListening()
        } else {
            wakeListener.stop()
            wakeStatus = "Wake phrase is off"
            if realtime == nil { state = .sleeping }
        }
    }

    func startWakeWordListening() {
        guard realtime == nil, wakeWordEnabled,
              !ProcessInfo.processInfo.arguments.contains("-DisableWakeWord") else { return }
        state = .sleeping
        wakeListener.requestPermissionAndStart()
    }

    func pauseWakeWordListening() {
        wakeListener.stop()
    }

    func triggerAssistant() {
        guard realtime == nil else { return }
        hideTask?.cancel()
        lastVoiceError = nil
        playActivationFeedback()
        wakeListener.stop()
        state = .thinking
        caption = "Connecting…"
        wakeStatus = "Voice mode is connecting"
        handleWake(transcript: "Hi Wall")
    }

    private func handleWake(transcript: String) {
        hideTask?.cancel()
        state = .thinking
        let command = Self.commandAfterWakeWord(in: transcript)
        caption = "Connecting…"
        wakeStatus = "Voice mode is connecting"

        let client = RealtimeClient()
        realtime = client
        client.onState = { [weak self, weak client] state in
            Task { @MainActor in
                guard let self, self.realtime === client else { return }
                self.state = state
                if state == .listening {
                    self.lastVoiceError = nil
                    self.wakeStatus = "Voice mode is listening"
                }
            }
        }
        client.onCaption = { [weak self, weak client] caption in
            Task { @MainActor in
                guard let self, self.realtime === client else { return }
                self.caption = caption
            }
        }
        client.onCancel = { [weak self] in
            Task { @MainActor in self?.onCancel?() }
        }
        client.onFinished = { [weak self, weak client] errorMessage in
            Task { @MainActor in
                guard let self, let client else { return }
                self.finish(client: client, errorMessage: errorMessage)
            }
        }
        client.connect(initialText: command)
    }

    private func playActivationFeedback() {
        activationHaptic.impactOccurred()
        activationHaptic.prepare()

        do {
            let player = try AVAudioPlayer(data: WakeActivationTone.wavData)
            player.volume = 0.65
            player.prepareToPlay()
            activationPlayer = player
            player.play()
        } catch {
            // The visual listening state and haptic still acknowledge the wake phrase.
            activationPlayer = nil
        }
    }

    private func finish(client: RealtimeClient, errorMessage: String?) {
        guard realtime === client else { return }
        realtime = nil
        if let errorMessage {
            lastVoiceError = errorMessage
            wakeStatus = errorMessage
            caption = errorMessage
            state = .unavailable
            hideTask?.cancel()
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                guard let self, !Task.isCancelled, self.realtime == nil else { return }
                self.caption = ""
                self.state = .sleeping
                if self.wakeWordEnabled { self.wakeListener.start() }
            }
        } else {
            caption = ""
            state = .sleeping
            if wakeWordEnabled { wakeListener.start() }
        }
    }

    nonisolated static func commandAfterWakeWord(in transcript: String) -> String {
        guard let range = WakePhrase.range(in: transcript) else { return "" }
        return transcript[range.upperBound...]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

enum WakeActivationTone {
    static let wavData = makeWAVData()

    static func makeWAVData(
        sampleRate: UInt32 = 44_100,
        duration: TimeInterval = 0.12
    ) -> Data {
        let sampleCount = max(1, Int(Double(sampleRate) * duration))
        let bytesPerSample = UInt16(2)
        let dataByteCount = UInt32(sampleCount) * UInt32(bytesPerSample)
        var data = Data()
        data.reserveCapacity(44 + Int(dataByteCount))

        appendASCII("RIFF", to: &data)
        appendLittleEndian(UInt32(36) + dataByteCount, to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * UInt32(bytesPerSample), to: &data)
        appendLittleEndian(bytesPerSample, to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        appendASCII("data", to: &data)
        appendLittleEndian(dataByteCount, to: &data)

        let attackSamples = max(1, Int(Double(sampleRate) * 0.006))
        let releaseSamples = max(1, Int(Double(sampleRate) * 0.04))
        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let attack = min(1, Double(index) / Double(attackSamples))
            let samplesRemaining = sampleCount - index
            let release = min(1, Double(samplesRemaining) / Double(releaseSamples))
            let envelope = min(attack, release)
            let fundamental = sin(2 * Double.pi * 880 * time)
            let overtone = sin(2 * Double.pi * 1_320 * time) * 0.28
            let normalized = max(-1, min(1, (fundamental + overtone) * envelope * 0.24))
            appendLittleEndian(Int16(normalized * Double(Int16.max)), to: &data)
        }
        return data
    }

    private static func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
