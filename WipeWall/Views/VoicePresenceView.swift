import SwiftUI

struct VoicePresenceView: View {
    @EnvironmentObject private var voice: DonVoiceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool { voice.state != .sleeping }

    var body: some View {
        ZStack {
            if isVisible {
                VStack(spacing: 26) {
                    HStack(spacing: 8) {
                        ForEach(0..<5, id: \.self) { index in
                            Capsule()
                                .fill(Color.black)
                                .frame(
                                    width: 4,
                                    height: voice.state == .listening
                                        ? CGFloat(16 + index % 3 * 16)
                                        : 16
                                )
                        }
                    }
                    .frame(height: 56)

                    if !voice.caption.isEmpty {
                        Text(voice.caption)
                            .font(.custom("Helvetica", size: 36))
                            .foregroundColor(.black)
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: 260)
                    }
                }
                .frame(width: 320, height: 320)
                .background(Color.white)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.84).combined(with: .opacity)
                )
            }
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .spring(response: 0.32, dampingFraction: 0.84),
            value: isVisible
        )
        .allowsHitTesting(false)
    }
}
