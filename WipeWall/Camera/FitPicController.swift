import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import Vision

struct FitPicLumaQuality {
    static func isUsable(samples: [UInt8]) -> Bool {
        guard !samples.isEmpty else { return false }
        let mean = Double(samples.reduce(0) { $0 + Int($1) }) / Double(samples.count)
        let brightSamples = samples.filter { $0 >= 24 }.count
        return mean >= 3.0 && brightSamples >= max(1, samples.count / 100)
    }
}

struct FitPicPresenceGate {
    static let requiredDwell: TimeInterval = 3
    static let lossTolerance: TimeInterval = 0.8

    private(set) var dwellStartedAt: Date?
    private(set) var lastSeenAt: Date?

    var hasSeenPerson: Bool { lastSeenAt != nil }

    mutating func observe(personPresent: Bool, at date: Date) -> Bool {
        if personPresent {
            if let lastSeenAt,
               date.timeIntervalSince(lastSeenAt) > Self.lossTolerance {
                dwellStartedAt = date
            } else if dwellStartedAt == nil {
                dwellStartedAt = date
            }
            lastSeenAt = date
            return date.timeIntervalSince(dwellStartedAt ?? date) >= Self.requiredDwell
        }

        if let lastSeenAt,
           date.timeIntervalSince(lastSeenAt) > Self.lossTolerance {
            reset()
        }
        return false
    }

    mutating func reset() {
        dwellStartedAt = nil
        lastSeenAt = nil
    }
}

private enum FitPicImageQuality {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func jpegIsUsable(_ data: Data) -> Bool {
        guard let image = CIImage(data: data), !image.extent.isEmpty,
              let filter = CIFilter(name: "CIAreaAverage") else { return false }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        let luma = 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
        return luma >= 2.5
    }
}

final class FitPicController: NSObject, ObservableObject {
    static let triggerCooldown: TimeInterval = 10 * 60
    static let presenceScanInterval: TimeInterval = 0.35
    static let emptyCandidateTimeout: TimeInterval = 1.5
    static let lastTriggerKey = "wall.fitpic.last-trigger"

    enum State: Equatable {
        case idle
        case counting(Int)
        case capturing
        case uploading
        case saved
        case unavailable
    }

    let session = AVCaptureSession()
    @Published private(set) var state: State = .idle
    @Published private(set) var previewOpacity = 0.0
    @Published private(set) var flashOpacity = 0.0
    @Published private(set) var canTrigger = true
    @Published private(set) var isAutomaticCountdown = false
    @Published var photoBoothEmailPrompt: PhotoBoothEmailPrompt?

    private let sessionQueue = DispatchQueue(label: "wall.camera.session")
    private let videoQueue = DispatchQueue(label: "wall.camera.motion")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let uploader = FitPicUploadClient()
    private var previousLuma: [UInt8]?
    private var motionFrames = 0
    private var isArmed = true
    private var presenceCandidateStartedAt: Date?
    private var lastPresenceScanAt = Date.distantPast
    private var presenceGate = FitPicPresenceGate()
    private var latestFrameIsUsable = false
    private var latestFrameDate: Date?
    private var blackCaptureRetries = 0
    private var countdownTask: Task<Void, Never>?
    private var captureSource: FitPicCaptureSource = .automatic
    private var photoBoothNight: String?
    private var pendingImmediateCaptures = 0

    func start() {
        refreshTriggerAvailability()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                DispatchQueue.main.async { self.state = .unavailable }
                return
            }
            self.sessionQueue.async { self.configureAndStart() }
            self.uploader.start()
        }
    }

    func stop() {
        countdownTask?.cancel()
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }

    func cancelCountdown() {
        guard case .counting = state else { return }
        countdownTask?.cancel()
        countdownTask = nil
        isAutomaticCountdown = false
        withAnimation(.easeOut(duration: 0.25)) { previewOpacity = 0 }
        state = .idle
        rearm(after: max(0.1, cooldownRemaining()))
    }

    func cancelAutomaticCountdown() {
        guard isAutomaticCountdown else { return }
        cancelCountdown()
    }

    func triggerManualCountdown() {
        triggerManualCountdown(source: .manual)
    }

    func triggerPhotoBoothCountdown() {
        triggerManualCountdown(source: .photoBooth)
    }

    /// Counter taps need the front camera immediately after their sound, with
    /// no countdown or preview. Requests are retained while another capture is
    /// finishing so rapid additions still produce one photo apiece.
    @MainActor
    func triggerImmediateCapture() {
        guard state != .unavailable else { return }
        pendingImmediateCaptures += 1
        if isAutomaticCountdown { cancelAutomaticCountdown() }
        startNextImmediateCaptureIfPossible()
    }

    @MainActor
    private func startNextImmediateCaptureIfPossible() {
        guard pendingImmediateCaptures > 0, state == .idle else { return }
        pendingImmediateCaptures -= 1
        UserDefaults.standard.set(Date(), forKey: Self.lastTriggerKey)
        canTrigger = false
        isAutomaticCountdown = false
        captureSource = .manual
        photoBoothNight = nil
        blackCaptureRetries = 0
        previewOpacity = 0
        state = .capturing
        captureWhenFrameReady(attempt: 0, showFlash: true)
    }

    private func triggerManualCountdown(source: FitPicCaptureSource) {
        guard state == .idle else { return }
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.isArmed = false
            self.resetPresenceCandidate()
        }
        beginCountdown(previewMode: .immediate, enforcesMotionCooldown: false, source: source)
    }

    private func configureAndStart() {
        guard !session.isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.state = .unavailable }
            return
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        applyCaptureOrientation(.portrait)

        session.commitConfiguration()
        session.startRunning()
    }

    private enum PreviewMode {
        case fading
        case immediate
    }

    private func beginCountdown(
        previewMode: PreviewMode,
        enforcesMotionCooldown: Bool,
        source: FitPicCaptureSource
    ) {
        guard state == .idle else { return }
        if enforcesMotionCooldown {
            let remaining = cooldownRemaining()
            guard remaining <= 0 else {
                canTrigger = false
                rearm(after: remaining)
                return
            }
        }

        UserDefaults.standard.set(Date(), forKey: Self.lastTriggerKey)
        canTrigger = false
        isAutomaticCountdown = enforcesMotionCooldown
        captureSource = source
        photoBoothNight = source == .photoBooth ? PhotoBoothNight.identifier() : nil
        blackCaptureRetries = 0
        countdownTask?.cancel()
        switch previewMode {
        case .fading:
            previewOpacity = 0.5
            withAnimation(.linear(duration: 5)) { previewOpacity = 1 }
        case .immediate:
            previewOpacity = 1
        }

        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for number in stride(from: 5, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                state = .counting(number)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            isAutomaticCountdown = false
            state = .capturing
            captureWhenFrameReady(attempt: 0, showFlash: true)
        }
    }

    @MainActor
    private func captureWhenFrameReady(attempt: Int, showFlash: Bool) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            let frameIsFresh = self.latestFrameDate.map { Date().timeIntervalSince($0) < 0.6 } ?? false
            let ready = self.latestFrameIsUsable && frameIsFresh
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if ready {
                    self.capturePhoto(showFlash: showFlash)
                } else if attempt < 12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.125) { [weak self] in
                        self?.captureWhenFrameReady(attempt: attempt + 1, showFlash: showFlash)
                    }
                } else {
                    self.abandonCapture()
                }
            }
        }
    }

    @MainActor
    private func capturePhoto(showFlash: Bool) {
        let orientation = Self.videoOrientation(for: Self.currentInterfaceOrientation())
        if showFlash {
            withAnimation(.linear(duration: 0.025)) { flashOpacity = 1 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + (showFlash ? 0.12 : 0)) { [weak self] in
            guard let self else { return }
            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                self.applyCaptureOrientation(orientation)
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .speed
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
            if showFlash {
                withAnimation(.easeOut(duration: 0.28)) { self.flashOpacity = 0 }
            }
        }
    }

    @MainActor
    private func abandonCapture() {
        withAnimation(.easeOut(duration: 0.2)) {
            previewOpacity = 0
            flashOpacity = 0
        }
        state = .idle
        isAutomaticCountdown = false
        rearm(after: max(0.1, cooldownRemaining()))
        startNextImmediateCaptureIfPossible()
    }

    private func applyCaptureOrientation(_ orientation: AVCaptureVideoOrientation) {
        [videoOutput.connection(with: .video), photoOutput.connection(with: .video)]
            .compactMap { $0 }
            .forEach { connection in
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
    }

    @MainActor
    private static func currentInterfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .portrait
    }

    static func videoOrientation(for interfaceOrientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        switch interfaceOrientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    static func visionOrientation(for videoOrientation: AVCaptureVideoOrientation) -> CGImagePropertyOrientation {
        switch videoOrientation {
        case .portrait: return .leftMirrored
        case .portraitUpsideDown: return .rightMirrored
        case .landscapeLeft: return .downMirrored
        case .landscapeRight: return .upMirrored
        @unknown default: return .leftMirrored
        }
    }

    private func rearm(after seconds: TimeInterval) {
        videoQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.previousLuma = nil
            self?.motionFrames = 0
            self?.resetPresenceCandidate()
            self?.isArmed = true
            DispatchQueue.main.async { self?.canTrigger = true }
        }
    }

    private func refreshTriggerAvailability() {
        let remaining = cooldownRemaining()
        canTrigger = remaining <= 0
        guard remaining > 0 else { return }
        videoQueue.async { [weak self] in self?.isArmed = false }
        rearm(after: remaining)
    }

    private func cooldownRemaining(now: Date = Date()) -> TimeInterval {
        Self.cooldownRemaining(
            now: now,
            lastTrigger: UserDefaults.standard.object(forKey: Self.lastTriggerKey) as? Date
        )
    }

    static func cooldownRemaining(now: Date, lastTrigger: Date?) -> TimeInterval {
        guard let lastTrigger else { return 0 }
        return max(0, triggerCooldown - now.timeIntervalSince(lastTrigger))
    }

    private func lumaSamples(from pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return [] }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var values: [UInt8] = []
        values.reserveCapacity(192)
        for y in stride(from: height / 24, to: height, by: max(1, height / 12)) {
            for x in stride(from: width / 32, to: width, by: max(1, width / 16)) {
                values.append(bytes[y * rowBytes + x])
            }
        }
        return values
    }

    private func resetPresenceCandidate() {
        presenceCandidateStartedAt = nil
        lastPresenceScanAt = .distantPast
        presenceGate.reset()
    }

    private func scanForSustainedPerson(
        in pixelBuffer: CVPixelBuffer,
        orientation: AVCaptureVideoOrientation,
        at date: Date
    ) {
        guard let candidateStartedAt = presenceCandidateStartedAt else { return }
        guard date.timeIntervalSince(lastPresenceScanAt) >= Self.presenceScanInterval else { return }
        lastPresenceScanAt = date

        let request = VNDetectHumanRectanglesRequest()
        request.revision = VNDetectHumanRectanglesRequestRevision1
        request.preferBackgroundProcessing = true
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: Self.visionOrientation(for: orientation),
            options: [:]
        )
        let personPresent: Bool
        do {
            try handler.perform([request])
            personPresent = (request.results ?? []).contains { observation in
                let box = observation.boundingBox
                return observation.confidence >= 0.35 && box.width * box.height >= 0.015
            }
        } catch {
            personPresent = false
        }

        if presenceGate.observe(personPresent: personPresent, at: date) {
            resetPresenceCandidate()
            DispatchQueue.main.async { [weak self] in
                self?.beginCountdown(
                    previewMode: .fading,
                    enforcesMotionCooldown: true,
                    source: .automatic
                )
            }
            return
        }

        if !presenceGate.hasSeenPerson,
           date.timeIntervalSince(candidateStartedAt) >= Self.emptyCandidateTimeout {
            resetPresenceCandidate()
            previousLuma = nil
            motionFrames = 0
            isArmed = true
        }
    }
}

extension FitPicController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        let current = lumaSamples(from: pixelBuffer)
        guard !current.isEmpty else { return }
        latestFrameIsUsable = FitPicLumaQuality.isUsable(samples: current)
        latestFrameDate = now
        defer { previousLuma = current }

        if presenceCandidateStartedAt != nil {
            scanForSustainedPerson(in: pixelBuffer, orientation: connection.videoOrientation, at: now)
            return
        }

        guard isArmed else { return }
        guard let previousLuma, previousLuma.count == current.count else { return }

        let total = zip(previousLuma, current).reduce(0) { partial, pair in
            partial + abs(Int(pair.0) - Int(pair.1))
        }
        let averageDifference = Double(total) / Double(current.count)
        motionFrames = averageDifference > 15 ? motionFrames + 1 : 0
        guard motionFrames >= 2 else { return }
        isArmed = false
        presenceCandidateStartedAt = now
        lastPresenceScanAt = .distantPast
        presenceGate.reset()
        scanForSustainedPerson(in: pixelBuffer, orientation: connection.videoOrientation, at: now)
    }
}

extension FitPicController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.abandonCapture() }
            return
        }

        guard FitPicImageQuality.jpegIsUsable(data) else {
            DispatchQueue.main.async {
                guard self.blackCaptureRetries < 3 else {
                    self.abandonCapture()
                    return
                }
                self.blackCaptureRetries += 1
                self.state = .capturing
                self.captureWhenFrameReady(attempt: 0, showFlash: false)
            }
            return
        }

        DispatchQueue.main.async {
            self.state = .uploading
            withAnimation(.easeOut(duration: 0.35)) { self.previewOpacity = 0 }
        }
        let completedSource = captureSource
        let completedNight = photoBoothNight
        uploader.enqueue(data, source: completedSource, photoBoothNight: completedNight) { [weak self] receipt in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state = receipt != nil ? .saved : .idle
                if completedSource == .photoBooth,
                   let receipt,
                   let completedNight {
                    self.photoBoothEmailPrompt = PhotoBoothEmailPrompt(
                        photoName: receipt.name,
                        night: completedNight
                    )
                }
                if self.pendingImmediateCaptures > 0 {
                    self.state = .idle
                    self.startNextImmediateCaptureIfPossible()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard self.state == .saved else { return }
                    self.state = .idle
                    self.startNextImmediateCaptureIfPossible()
                }
            }
        }
        rearm(after: max(0.1, cooldownRemaining()))
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewSurface, context: Context) {
        uiView.setNeedsLayout()
    }

    final class PreviewSurface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let interfaceOrientation = window?.windowScene?.interfaceOrientation,
                  let connection = previewLayer.connection else { return }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = FitPicController.videoOrientation(for: interfaceOrientation)
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }
}

struct FitPicOverlayView: View {
    @ObservedObject var controller: FitPicController

    var body: some View {
        ZStack {
            if controller.previewOpacity > 0 {
                CameraPreviewView(session: controller.session)
                    .ignoresSafeArea()
                    .opacity(controller.previewOpacity)

                if case let .counting(number) = controller.state {
                    Text("\(number)")
                        .font(.custom("Helvetica", size: 144).weight(.bold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.55), radius: 2)
                }
            }

            if controller.flashOpacity > 0 {
                Color.white
                    .ignoresSafeArea()
                    .opacity(controller.flashOpacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            controller.cancelAutomaticCountdown()
        }
        .allowsHitTesting(controller.isAutomaticCountdown)
        .accessibilityLabel(controller.isAutomaticCountdown ? "Cancel automatic fit pic" : "")
        .accessibilityIdentifier("wall.fitpic.auto-cancel")
        .accessibilityHidden(!controller.isAutomaticCountdown)
    }
}

struct FitPicCameraButton: View {
    @ObservedObject var controller: FitPicController

    var body: some View {
        InstantActionButton {
            controller.triggerManualCountdown()
        } label: {
            Image(systemName: "camera")
                .font(.system(size: 25, weight: .regular))
                .foregroundColor(.white)
                .frame(width: 58, height: 54)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .zIndex(100)
        .accessibilityLabel("Take a fit pic")
        .accessibilityIdentifier("wall.camera.button")
    }
}
