import SwiftUI
import UIKit

struct WallClockView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(WallClockText.date(for: now))
                .font(.custom("Helvetica", size: 12).weight(.medium))
                .tracking(0.4)

            Text(WallClockText.time(for: now))
                .font(.custom("Helvetica", size: 144).weight(.bold))
                .tracking(-5)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .monospacedDigit()
        }
        .foregroundColor(.black)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }

            // A Combine autoconnect timer can remain cancelled after iOS suspends
            // the process. A scene-bound task is recreated on every foreground and
            // immediately catches the display up to wall-clock time.
            now = Date()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                now = Date()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            now = Date()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.formatted(date: .omitted, time: .shortened))
        .accessibilityIdentifier("wall.clock.display")
    }
}

enum WallClockText {
    static func time(for date: Date, calendar: Calendar = .current) -> String {
        let hour24 = calendar.component(.hour, from: date)
        let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
        let minute = calendar.component(.minute, from: date)
        return String(format: "%d:%02d", hour, minute)
    }

    static func date(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date).uppercased()
    }
}
