import AVFoundation
import Foundation
import Speech

final class WakeWordListener: NSObject, SFSpeechRecognizerDelegate {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartWorkItem: DispatchWorkItem?
    private var deliveryWorkItem: DispatchWorkItem?
    private var heardWakeWord = false
    private var latestTranscript = ""
    private var tapInstalled = false
    private var permissionRequestInFlight = false
    private var desiredRunning = false
    private var generation = 0
    private var consecutiveFailures = 0
    private var trackedWordCounter = TrackedWordCounter()

    var onWake: ((String) -> Void)?
    var onWakeDetected: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onTranscriptChange: ((String) -> Void)?
    var onTrackedWordsDetected: ((Int) -> Void)?

    override init() {
        super.init()
        recognizer?.delegate = self
    }

    func requestPermissionAndStart() {
        desiredRunning = true
        let speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized
        let microphoneAllowed = AVAudioSession.sharedInstance().recordPermission == .granted
        if speechAllowed && microphoneAllowed {
            onAvailabilityChange?(true)
            startIfNeeded()
            return
        }

        guard !permissionRequestInFlight else { return }
        permissionRequestInFlight = true
        onStatusChange?("Waiting for voice access")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            AVAudioSession.sharedInstance().requestRecordPermission { microphoneAllowed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permissionRequestInFlight = false
                    let allowed = status == .authorized && microphoneAllowed
                    self.onAvailabilityChange?(allowed)
                    guard self.desiredRunning else { return }
                    if allowed {
                        self.startIfNeeded()
                    } else {
                        self.onStatusChange?("Microphone or Speech access is off")
                    }
                }
            }
        }
    }

    func start() {
        desiredRunning = true
        startIfNeeded()
    }

    func stop() {
        desiredRunning = false
        generation += 1
        consecutiveFailures = 0
        restartWorkItem?.cancel()
        restartWorkItem = nil
        deliveryWorkItem?.cancel()
        deliveryWorkItem = nil
        tearDownRecognition()
    }

    private func startIfNeeded() {
        guard desiredRunning, !permissionRequestInFlight,
              restartWorkItem == nil, task == nil, !audioEngine.isRunning else { return }
        beginRecognition()
    }

    private func beginRecognition() {
        guard desiredRunning else { return }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        generation += 1
        let sessionGeneration = generation
        heardWakeWord = false
        latestTranscript = ""
        trackedWordCounter.reset()

        guard let recognizer else {
            onAvailabilityChange?(false)
            retry(afterFailureIn: sessionGeneration, status: "Speech recognition is unavailable")
            return
        }
        guard recognizer.isAvailable else {
            onAvailabilityChange?(false)
            retry(afterFailureIn: sessionGeneration, status: "Waiting for speech recognition")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // Keep an output route available while the microphone is open so Wall can
            // acknowledge a wake phrase without tearing down the speech recognizer.
            // `defaultToSpeaker` is important on older iPads, where play-and-record can
            // otherwise choose an inaudible route.
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker]
            )
            try session.setActive(true)

            // iOS can leave the engine graph stale after an interruption or foreground
            // transition even though the task object still exists. A stopped-engine reset
            // gives each recognition generation a fresh hardware graph.
            audioEngine.reset()

            // `.measurement` deliberately minimizes input dynamics, which made
            // the wall-mounted iPad require an unnaturally loud wake phrase.
            // Voice processing is not enabled by `.voiceChat` alone: explicitly
            // turn it on while the graph is stopped so its AGC can lift normal
            // room-volume speech. Older hardware can reject the graph change;
            // in that case use the normal processed input path rather than an
            // unprocessed voice-chat session.
            let node = audioEngine.inputNode
            do {
                try node.setVoiceProcessingEnabled(true)
                guard node.isVoiceProcessingEnabled else {
                    throw NSError(domain: "Wall.WakeWord", code: 2)
                }
                node.isVoiceProcessingAGCEnabled = true
            } catch {
                try? node.setVoiceProcessingEnabled(false)
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker]
                )
                audioEngine.reset()
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.contextualStrings = [
                "Hi Wall", "Hey Wall", "Yo Wall", "Hi, Wall", "High Wall", "HiWall",
                "Wally", "Hi well", "Hi all", "Hi world", "Hi y'all",
                "retard", "retarded"
            ]
            request.taskHint = .dictation
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request

            // Start the consumer before the audio engine produces its first buffer. On
            // iOS 15, starting the graph first can lose the opening syllable of a short
            // phrase such as "Hi Wall".
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self, self.desiredRunning,
                          self.generation == sessionGeneration else { return }
                    self.handleRecognition(result: result, error: error, generation: sessionGeneration)
                }
            }

            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(
                    domain: "Wall.WakeWord",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone input format is unavailable."]
                )
            }
            if tapInstalled {
                node.removeTap(onBus: 0)
                tapInstalled = false
            }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()

            onAvailabilityChange?(true)
            onStatusChange?("Listening for “Hi Wall”")
            scheduleHealthyRefresh(for: sessionGeneration)
        } catch {
            retry(
                afterFailureIn: sessionGeneration,
                status: Self.readableFailure(error, prefix: "Couldn’t start the wake listener")
            )
        }
    }

    private func handleRecognition(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        generation sessionGeneration: Int
    ) {
        if let result {
            consecutiveFailures = 0
            let transcript = result.bestTranscription.formattedString
            onTranscriptChange?(transcript)
            let newlyDetected = trackedWordCounter.delta(for: transcript)
            if newlyDetected > 0 { onTrackedWordsDetected?(newlyDetected) }
            let words = transcript.lowercased().split(whereSeparator: { !$0.isLetter })
            if words.contains("cancel") { onCancel?() }

            if heardWakeWord || WakePhrase.range(in: transcript) != nil {
                if !heardWakeWord {
                    heardWakeWord = true
                    onWakeDetected?()
                }
                latestTranscript = transcript
                scheduleDelivery(after: result.isFinal ? 0.12 : 0.9, generation: sessionGeneration)
            }
        }

        if !heardWakeWord, error != nil || result?.isFinal == true {
            let status = error.map {
                Self.readableFailure($0, prefix: "Wake listener stopped")
            } ?? "Listening for “Hi Wall”"
            retry(afterFailureIn: sessionGeneration, status: status)
        }
    }

    private static func readableFailure(_ error: Error, prefix: String) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? prefix : "\(prefix): \(message)"
    }

    private func retry(afterFailureIn sessionGeneration: Int, status: String) {
        guard desiredRunning, generation == sessionGeneration else { return }
        consecutiveFailures += 1
        let exponent = min(max(consecutiveFailures - 1, 0), 4)
        let delay = min(pow(2.0, Double(exponent)), 15)
        prepareNextSession(after: delay, status: status)
    }

    private func scheduleHealthyRefresh(for sessionGeneration: Int) {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.desiredRunning,
                  self.generation == sessionGeneration else { return }
            self.prepareNextSession(after: 0.15, status: "Listening for “Hi Wall”")
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 50, execute: item)
    }

    private func prepareNextSession(after delay: TimeInterval, status: String) {
        guard desiredRunning else { return }
        generation += 1
        let restartGeneration = generation
        restartWorkItem?.cancel()
        restartWorkItem = nil
        deliveryWorkItem?.cancel()
        deliveryWorkItem = nil
        tearDownRecognition()
        onStatusChange?(status)

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.desiredRunning,
                  self.generation == restartGeneration else { return }
            self.restartWorkItem = nil
            self.beginRecognition()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleDelivery(after delay: TimeInterval, generation sessionGeneration: Int) {
        deliveryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.desiredRunning, self.heardWakeWord,
                  self.generation == sessionGeneration else { return }
            let transcript = self.latestTranscript
            self.stop()
            self.onWake?(transcript)
        }
        deliveryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func tearDownRecognition() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.desiredRunning else { return }
            self.onAvailabilityChange?(available)
            if available {
                self.startIfNeeded()
            } else if self.task == nil {
                self.onStatusChange?("Waiting for speech recognition")
            }
        }
    }
}

/// Counts only new exact appearances as a partial Speech transcript grows.
/// A recognition pass often reports the same words many times; keeping the
/// highest observed count prevents one spoken word from inflating the tally.
struct TrackedWordCounter {
    private(set) var deliveredCount = 0

    mutating func reset() {
        deliveredCount = 0
    }

    mutating func delta(for transcript: String) -> Int {
        let count = Self.count(in: transcript)
        guard count > deliveredCount else { return 0 }
        defer { deliveredCount = count }
        return count - deliveredCount
    }

    static func count(in transcript: String) -> Int {
        transcript
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .count { $0 == "retard" || $0 == "retarded" }
    }
}

enum WakePhrase {
    private static let expression = try! NSRegularExpression(
        pattern: #"\b(?:(?:hi|high|hey|hai|yo)[\s,.;:!?'’\-]*(?:wall|well|while|walt|wal|all|woah|world|y[’']?all)|wally)\b"#,
        options: [.caseInsensitive]
    )

    static func range(in transcript: String) -> Range<String.Index>? {
        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard let match = expression.firstMatch(in: transcript, range: fullRange) else { return nil }
        return Range(match.range, in: transcript)
    }
}
