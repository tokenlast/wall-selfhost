import SwiftUI
import UIKit

private struct WallModalInactivityModifier: ViewModifier {
    let timeout: TimeInterval
    let onTimeout: () -> Void

    @State private var timeoutTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(
                WallModalActivityBridge(onActivity: restartTimer)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            )
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification)) { _ in
                restartTimer()
            }
            .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidChangeNotification)) { _ in
                restartTimer()
            }
            .onAppear(perform: restartTimer)
            .onDisappear { timeoutTask?.cancel() }
    }

    private func restartTimer() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onTimeout()
        }
    }
}

extension View {
    /// Dismisses a transient Wall surface after twenty seconds without a
    /// touch or edit. The observer is installed at the window level with
    /// `cancelsTouchesInView = false`, so it never competes with the modal's
    /// buttons, sliders, fields, scrolling, or navigation.
    func wallAutoDismissModal(
        after timeout: TimeInterval = 20,
        onTimeout: @escaping () -> Void
    ) -> some View {
        modifier(WallModalInactivityModifier(timeout: timeout, onTimeout: onTimeout))
    }

    func wallAutoDismissModal(after timeout: TimeInterval = 20) -> some View {
        modifier(WallEnvironmentModalInactivityModifier(timeout: timeout))
    }
}

private struct WallEnvironmentModalInactivityModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let timeout: TimeInterval

    func body(content: Content) -> some View {
        content.wallAutoDismissModal(after: timeout) { dismiss() }
    }
}

private struct WallModalActivityBridge: UIViewRepresentable {
    let onActivity: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onActivity: onActivity)
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.install(on: window)
        }
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.onActivity = onActivity
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
        var onActivity: () -> Void
        private weak var installedWindow: UIWindow?
        private lazy var recognizer: UILongPressGestureRecognizer = {
            let value = UILongPressGestureRecognizer(target: self, action: #selector(observedTouch(_:)))
            value.minimumPressDuration = 0
            value.allowableMovement = .greatestFiniteMagnitude
            value.cancelsTouchesInView = false
            value.delaysTouchesBegan = false
            value.delaysTouchesEnded = false
            value.delegate = self
            return value
        }()

        init(onActivity: @escaping () -> Void) {
            self.onActivity = onActivity
        }

        func install(on window: UIWindow?) {
            guard installedWindow !== window else { return }
            uninstall()
            installedWindow = window
            window?.addGestureRecognizer(recognizer)
        }

        func uninstall() {
            installedWindow?.removeGestureRecognizer(recognizer)
            installedWindow = nil
        }

        @objc private func observedTouch(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onActivity()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
