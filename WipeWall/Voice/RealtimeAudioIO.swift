import AVFoundation
import Foundation

final class RealtimeAudioIO {
    var onMicrophoneAudio: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!
    private var inputConverter: AVAudioConverter?
    private var outputConverter: AVAudioConverter?
    private var playbackFormat: AVAudioFormat?
    private var inputTapInstalled = false
    private let playbackLock = NSLock()
    private var pendingPlaybackBuffers = 0
    private var playbackDrainHandlers: [() -> Void] = []

    func start() throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let playbackRate = session.sampleRate > 0 ? session.sampleRate : 44_100
        let playbackChannels = AVAudioChannelCount(max(session.outputNumberOfChannels, 1))
        guard let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: playbackRate,
            channels: playbackChannels
        ), let outputConverter = AVAudioConverter(from: wireFormat, to: playbackFormat) else {
            throw NSError(
                domain: "Wall.RealtimeAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The iPad audio mixer format is unavailable."]
            )
        }
        self.playbackFormat = playbackFormat
        self.outputConverter = outputConverter

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        inputConverter = AVAudioConverter(from: inputFormat, to: wireFormat)
        input.installTap(onBus: 0, bufferSize: 1_920, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndSend(buffer)
        }
        inputTapInstalled = true
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        stopMicrophone()
        if engine.isRunning {
            player.stop()
            engine.stop()
        }
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        inputConverter = nil
        outputConverter = nil
        playbackFormat = nil
        playbackLock.lock()
        pendingPlaybackBuffers = 0
        playbackDrainHandlers.removeAll()
        playbackLock.unlock()
    }

    /// Stops capture immediately while leaving the output graph alive long
    /// enough to play a terminal tool confirmation.
    func stopMicrophone() {
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        inputConverter = nil
    }

    func whenPlaybackDrains(_ handler: @escaping () -> Void) {
        playbackLock.lock()
        if pendingPlaybackBuffers == 0 {
            playbackLock.unlock()
            DispatchQueue.main.async(execute: handler)
        } else {
            playbackDrainHandlers.append(handler)
            playbackLock.unlock()
        }
    }

    func play(_ data: Data) {
        guard !data.isEmpty,
              let outputConverter,
              let playbackFormat,
              let source = AVAudioPCMBuffer(
                pcmFormat: wireFormat,
                frameCapacity: AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
              ) else { return }
        source.frameLength = source.frameCapacity
        data.withUnsafeBytes { rawBytes in
            guard let sourceAddress = rawBytes.baseAddress,
                  let destination = source.int16ChannelData?[0] else { return }
            destination.update(from: sourceAddress.assumingMemoryBound(to: Int16.self), count: data.count / 2)
        }

        let ratio = playbackFormat.sampleRate / wireFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = outputConverter.convert(to: output, error: &error) { _, conversionStatus in
            guard !supplied else {
                conversionStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            conversionStatus.pointee = .haveData
            return source
        }
        guard error == nil, status != .error, output.frameLength > 0 else { return }
        playbackLock.lock()
        pendingPlaybackBuffers += 1
        playbackLock.unlock()
        player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.playbackBufferDidFinish()
        }
        if !player.isPlaying { player.play() }
    }

    private func playbackBufferDidFinish() {
        playbackLock.lock()
        pendingPlaybackBuffers = max(0, pendingPlaybackBuffers - 1)
        let handlers: [() -> Void]
        if pendingPlaybackBuffers == 0 {
            handlers = playbackDrainHandlers
            playbackDrainHandlers.removeAll()
        } else {
            handlers = []
        }
        playbackLock.unlock()
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async { handlers.forEach { $0() } }
    }

    private func convertAndSend(_ input: AVAudioPCMBuffer) {
        guard let inputConverter else { return }
        let ratio = wireFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = inputConverter.convert(to: output, error: &error) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, status != .error, output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else { return }
        onMicrophoneAudio?(Data(bytes: samples, count: Int(output.frameLength) * 2))
    }
}
