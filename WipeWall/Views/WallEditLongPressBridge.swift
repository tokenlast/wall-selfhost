import SwiftUI
import UIKit

/// Observes completed taps during edit mode without cancelling child controls.
/// The wall decides whether the tapped point selects the topmost object or is
/// genuinely empty canvas. Because this is a tap recognizer, dragging the
/// selected object across another one can never switch selection.
struct WallEditTapBridge: UIViewRepresentable {
    let onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: self)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var anchor: AnchorView?
        private weak var installedWindow: UIWindow?
        var onTap: (CGPoint) -> Void
        private let recognizer = UITapGestureRecognizer()

        init(onTap: @escaping (CGPoint) -> Void) {
            self.onTap = onTap
            super.init()
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handleTap(_:)))
        }

        func attach(to anchor: AnchorView) {
            self.anchor = anchor
            guard let window = anchor.window else { return }
            guard installedWindow !== window else { return }
            installedWindow?.removeGestureRecognizer(recognizer)
            window.addGestureRecognizer(recognizer)
            installedWindow = window
        }

        func detach() {
            installedWindow?.removeGestureRecognizer(recognizer)
            installedWindow = nil
            anchor = nil
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let anchor else { return }
            onTap(recognizer.location(in: anchor))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}
