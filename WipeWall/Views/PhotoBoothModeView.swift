import SwiftUI
import UIKit

struct PhotoBoothEmailPromptView: View {
    let prompt: PhotoBoothEmailPrompt
    let onDismiss: () -> Void

    @State private var email = ""
    @State private var status = ""
    @State private var isSaving = false
    @State private var hasTyped = false
    @State private var dismissTask: Task<Void, Never>?
    @FocusState private var emailFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismissPrompt)
                .accessibilityIdentifier("wall.photo-booth.email.backdrop")

            VStack(alignment: .leading, spacing: 18) {
                Text("GET THE PHOTO BOOTH VIDEO")
                    .font(.custom("Helvetica-Bold", size: 22))
                    .foregroundColor(.black)

                TextField("email", text: $email)
                    .font(.custom("Helvetica-Bold", size: 22))
                    .foregroundColor(.black)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .disableAutocorrection(true)
                    .submitLabel(.done)
                    .focused($emailFocused)
                    .padding(.horizontal, 12)
                    .frame(height: 52)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
                    .onSubmit { save() }

                HStack {
                    Text(status)
                        .font(.custom("Helvetica-Bold", size: 11))
                        .foregroundColor(.black.opacity(0.6))
                    Spacer()
                    Button("DONE", action: dismissPrompt)
                        .font(.custom("Helvetica-Bold", size: 14))
                        .foregroundColor(.white)
                        .frame(width: 92, height: 42)
                        .background(Color.black)
                        .buttonStyle(WallPhotoBoothPromptPressStyle())
                        .accessibilityIdentifier("wall.photo-booth.email.done")
                }
            }
            .padding(24)
            .frame(width: 460)
            .background(Color.white)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
        }
        .onDisappear { dismissTask?.cancel() }
        .onChange(of: email) { value in
            guard !value.isEmpty else { return }
            hasTyped = true
            status = ""
            scheduleTypingIdleSave()
        }
        .accessibilityIdentifier("wall.photo-booth.email-prompt")
    }

    private func scheduleTypingIdleSave() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(PhotoBoothEmailPolicy.typingIdleDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func dismissPrompt() {
        dismissTask?.cancel()
        emailFocused = false
        onDismiss()
    }

    private func save() {
        dismissTask?.cancel()
        guard PhotoBoothEmailPolicy.isPlausible(email) else {
            status = "ENTER A COMPLETE EMAIL"
            return
        }
        guard !isSaving else { return }
        isSaving = true
        status = "SAVING…"
        Task {
            let saved = await PhotoBoothGuestClient.shared.save(email: email, prompt: prompt)
            await MainActor.run {
                if saved {
                    status = "SAVED"
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        onDismiss()
                    }
                } else {
                    isSaving = false
                    status = "COULDN’T SAVE — TRY AGAIN"
                }
            }
        }
    }
}

private struct WallPhotoBoothPromptPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct PhotoBoothModeView: View {
    @ObservedObject var controller: FitPicController
    let onOpenGallery: () -> Void
    let onOpenMusic: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 700
            ZStack {
                VStack(spacing: compact ? 22 : 28) {
                    InstantActionButton {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        controller.triggerPhotoBoothCountdown()
                    } label: {
                        Image(systemName: "camera")
                            .font(.system(size: compact ? 82 : 106, weight: .regular))
                            .foregroundColor(.white)
                            .frame(width: compact ? 220 : 280, height: compact ? 204 : 260)
                            .background(Color.black)
                    }
                    .accessibilityLabel("Take a photo booth picture")
                    .accessibilityIdentifier("wall.photo-booth.shutter")

                    PhotoBoothAnimatedTitle(fontSize: compact ? 63 : 87)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .fixedSize()
                }

                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        InstantActionButton(action: onOpenGallery) {
                            Image(systemName: "play.rectangle.on.rectangle.fill")
                                .font(.system(size: compact ? 28 : 34, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: compact ? 76 : 92, height: compact ? 68 : 80)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .accessibilityLabel("Open tonight's Photo Booth video")
                        .accessibilityIdentifier("wall.photo-booth.gallery")

                        InstantActionButton(action: onOpenMusic) {
                            Image(systemName: "music.note")
                                .font(.system(size: compact ? 28 : 34, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: compact ? 76 : 92, height: compact ? 68 : 80)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .accessibilityLabel("Open protected music controls")
                        .accessibilityIdentifier("wall.photo-booth.music")
                        Spacer()
                    }
                    .padding(.leading, 18)
                    .padding(.bottom, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wall.photo-booth.mode")
    }
}

private struct PhotoBoothAnimatedTitle: View {
    let fontSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let title = "PHOTO BOOTH"
    private let colors = Array(repeating: Color.black, count: 5)

    var body: some View {
        Group {
            if reduceMotion {
                Text(title).foregroundColor(.black)
            } else {
                TimelineView(.animation(minimumInterval: 0.12)) { context in
                    animatedTitle(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .font(.custom("Helvetica-Bold", size: fontSize))
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .frame(height: fontSize * 1.22)
    }

    @ViewBuilder
    private func animatedTitle(time: TimeInterval) -> some View {
        let style = Int(time / 2.4) % 5
        switch style {
        case 0:
            Text(unicodeShifted(title, tick: Int(time * 3)))
                .foregroundColor(colors[0])
        case 1:
            Text(title)
                .foregroundStyle(
                    LinearGradient(
                        colors: colors + [colors[0]],
                        startPoint: UnitPoint(x: (time.truncatingRemainder(dividingBy: 2.4) / 2.4) - 0.5, y: 0),
                        endPoint: UnitPoint(x: (time.truncatingRemainder(dividingBy: 2.4) / 2.4) + 0.5, y: 1)
                    )
                )
        case 2:
            Text(title)
                .foregroundColor(colors[2])
                .opacity(time.truncatingRemainder(dividingBy: 0.72) < 0.48 ? 1 : 0.16)
        case 3:
            animatedLetters(time: time, falling: true, color: colors[3])
        default:
            animatedLetters(time: time, falling: false, color: colors[4])
        }
    }

    private func animatedLetters(time: TimeInterval, falling: Bool, color: Color) -> some View {
        HStack(spacing: -fontSize * 0.03) {
            ForEach(Array(title.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .foregroundColor(color)
                    .offset(y: letterOffset(index: index, time: time, falling: falling))
            }
        }
        .frame(height: fontSize * 1.22)
        .clipped()
    }

    private func letterOffset(index: Int, time: TimeInterval, falling: Bool) -> CGFloat {
        if falling {
            let phase = (time + Double(index) * 0.18).truncatingRemainder(dividingBy: 5.8)
            if phase > 1.8 && phase < 2.8 { return fontSize * 0.72 }
            if phase >= 2.8 && phase < 3.35 { return -fontSize * 0.72 }
            return 0
        }
        return sin(time * 4.2 + Double(index) * 0.75) * fontSize * 0.08
    }

    private func unicodeShifted(_ value: String, tick: Int) -> String {
        let styles = [0x1D400, 0x1D5D4, 0xFF21, 0x24B6]
        return String(value.enumerated().map { index, character in
            guard let scalar = character.unicodeScalars.first else { return character }
            let code = Int(scalar.value)
            guard (65...90).contains(code),
                  let shifted = UnicodeScalar(styles[(tick + index) % styles.count] + code - 65) else {
                return character
            }
            return Character(String(shifted))
        })
    }
}

enum PhotoBoothGIFAssets {
    static let names = (1...4).map { "photo-booth-\($0)" }

    static func data(for index: Int, bundle: Bundle = .main) -> Data? {
        guard names.indices.contains(index - 1),
              let url = bundle.url(forResource: names[index - 1], withExtension: "gif") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}

/// Installs a non-blocking three-finger swipe recognizer on Wall's window.
/// Attaching at the window level lets the gesture begin over a GIF, clock, or
/// blank canvas without adding a touch-stealing SwiftUI overlay.
struct WallThreeFingerSwipeBridge: UIViewRepresentable {
    let onSwipe: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipe: onSwipe)
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.install(on: window)
        }
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.onSwipe = onSwipe
        context.coordinator.install(on: uiView.window)
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class AnchorView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            false
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSwipe: () -> Void
        private weak var installedWindow: UIWindow?
        private var recognizers: [UISwipeGestureRecognizer] = []
        private var lastTrigger = Date.distantPast

        init(onSwipe: @escaping () -> Void) {
            self.onSwipe = onSwipe
        }

        func install(on window: UIWindow?) {
            guard let window, installedWindow !== window else { return }
            uninstall()
            installedWindow = window
            recognizers = [
                makeRecognizer(.left),
                makeRecognizer(.right),
                makeRecognizer(.up),
                makeRecognizer(.down)
            ]
            recognizers.forEach(window.addGestureRecognizer)
        }

        func uninstall() {
            if let installedWindow {
                recognizers.forEach(installedWindow.removeGestureRecognizer)
            }
            recognizers = []
            installedWindow = nil
        }

        private func makeRecognizer(_ direction: UISwipeGestureRecognizer.Direction) -> UISwipeGestureRecognizer {
            let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(didSwipe))
            recognizer.direction = direction
            recognizer.numberOfTouchesRequired = 3
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }

        @objc private func didSwipe() {
            guard Date().timeIntervalSince(lastTrigger) > 0.35 else { return }
            lastTrigger = Date()
            onSwipe()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
