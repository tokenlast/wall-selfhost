import SwiftUI

/// A normal button with immediate pressed-state feedback. Actions still commit
/// on touch-up so a deliberate canvas long-press can enter edit mode without
/// accidentally firing the control underneath it.
struct InstantActionButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(WallImmediateButtonStyle())
    }
}

private struct WallImmediateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
