import SwiftUI
import UIKit

enum WallTransformGesturePhase {
    case began
    case changed
    case ended
    case cancelled
}

/// A deliberately small UIKit gesture island for edit mode. SwiftUI on iOS 15
/// can let a one-finger DragGesture win over pinch/rotation recognizers. Keeping
/// pan to one finger and allowing pinch + rotation to recognize together makes
/// the transform surface deterministic while the SwiftUI controls above it
/// remain ordinary Buttons.
struct WallTransformGestureSurface: UIViewRepresentable {
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let accessibilityValue: String
    let onTap: () -> Void
    let onPan: (WallTransformGesturePhase, CGSize) -> Void
    let onPinch: (WallTransformGesturePhase, CGFloat) -> Void
    let onRotation: (WallTransformGesturePhase, Angle) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = accessibilityIdentifier
        view.accessibilityValue = accessibilityValue

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let rotation = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.rotate(_:)))

        for recognizer in [tap, pan, pinch, rotation] {
            recognizer.delegate = context.coordinator
            recognizer.cancelsTouchesInView = true
            view.addGestureRecognizer(recognizer)
        }
        tap.require(toFail: pan)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = accessibilityIdentifier
        view.accessibilityValue = accessibilityValue
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: WallTransformGestureSurface

        init(parent: WallTransformGestureSurface) {
            self.parent = parent
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onTap()
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            parent.onPan(
                Self.phase(for: recognizer.state),
                CGSize(width: translation.x, height: translation.y)
            )
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            parent.onPinch(Self.phase(for: recognizer.state), recognizer.scale)
        }

        @objc func rotate(_ recognizer: UIRotationGestureRecognizer) {
            parent.onRotation(
                Self.phase(for: recognizer.state),
                .radians(Double(recognizer.rotation))
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            let pair = [gestureRecognizer, otherGestureRecognizer]
            // A real two-finger gesture arrives one finger at a time. On iOS
            // 15 the one-finger pan can begin during that short interval and
            // otherwise block the later rotation recognizer. Let all direct
            // manipulation recognizers coexist; pan cancels itself when the
            // second touch exceeds its one-touch maximum, while rotation and
            // pinch continue normally.
            let directTypes = pair.map {
                $0 is UIPanGestureRecognizer
                    || $0 is UIPinchGestureRecognizer
                    || $0 is UIRotationGestureRecognizer
            }
            return directTypes.allSatisfy { $0 }
        }

        private static func phase(for state: UIGestureRecognizer.State) -> WallTransformGesturePhase {
            switch state {
            case .began: return .began
            case .changed: return .changed
            case .ended: return .ended
            default: return .cancelled
            }
        }
    }
}

/// An unselected object gets only a tap target in edit mode. Keeping transform
/// recognizers off unselected objects prevents them from stealing an active
/// drag when the selected object crosses above them.
struct WallObjectSelectionSurface: View {
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Long-press belongs to an object, never to the window. Keeping the gesture
/// simultaneous means ordinary controls remain immediate; once the hold wins,
/// the object enters edit mode and the canvas cancels any in-progress ink.
extension View {
    func wallObjectEditLongPress(
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        simultaneousGesture(
            LongPressGesture(minimumDuration: 0.55, maximumDistance: 18)
                .onEnded { completed in
                    guard completed, enabled else { return }
                    action()
                },
            including: enabled ? .all : .none
        )
    }
}
