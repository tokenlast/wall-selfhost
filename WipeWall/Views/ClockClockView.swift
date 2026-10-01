import SwiftUI

struct ClockClockView: View {
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dateText)
                .font(.custom("Helvetica", size: 12).weight(.medium))
                .tracking(0.4)
                .foregroundColor(.black)

            TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
                LEDMatrixTimeView(date: now, animationDate: timeline.date)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .onReceive(timer) { now = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.formatted(date: .omitted, time: .shortened))
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: now).uppercased()
    }
}

private struct LEDMatrixTimeView: View {
    let date: Date
    let animationDate: Date

    var body: some View {
        Canvas { context, size in
            let phase = animationDate.timeIntervalSinceReferenceDate
            let colonOn = phase.truncatingRemainder(dividingBy: 1) < 0.62
            let pattern = LEDMatrixClockPattern.pattern(for: date, colonOn: colonOn)
            let rows = pattern.count
            let columns = pattern.first?.count ?? 0
            guard rows > 0, columns > 0 else { return }

            let pitch = min((size.width - 26) / CGFloat(columns), (size.height - 24) / CGFloat(rows))
            let dot = max(4, pitch * 0.58)
            let matrixWidth = CGFloat(columns - 1) * pitch + dot
            let matrixHeight = CGFloat(rows - 1) * pitch + dot
            let origin = CGPoint(
                x: (size.width - matrixWidth) / 2,
                y: (size.height - matrixHeight) / 2
            )

            for row in 0..<rows {
                for column in 0..<columns {
                    let rect = CGRect(
                        x: origin.x + CGFloat(column) * pitch,
                        y: origin.y + CGFloat(row) * pitch,
                        width: dot,
                        height: dot
                    )
                    let circle = Path(ellipseIn: rect)
                    guard pattern[row][column] else {
                        context.fill(circle, with: .color(Color.white.opacity(0.055)))
                        continue
                    }

                    let hue = (Double(column) / Double(columns) + phase / 9)
                        .truncatingRemainder(dividingBy: 1)
                    let flicker = 0.91 + 0.09 * sin(phase * 11 + Double(column * 3 + row))
                    let color = Color(hue: hue, saturation: 0.88, brightness: flicker)
                    context.drawLayer { glow in
                        glow.addFilter(.shadow(color: color.opacity(0.9), radius: dot * 0.52))
                        glow.fill(circle, with: .color(color))
                    }
                    context.fill(circle, with: .color(color))
                    context.fill(
                        Path(ellipseIn: rect.insetBy(dx: dot * 0.23, dy: dot * 0.23)),
                        with: .color(.white.opacity(0.36))
                    )
                }
            }
        }
        .background(Color(red: 0.018, green: 0.02, blue: 0.026))
    }
}

enum LEDMatrixClockPattern {
    private static let digits: [[String]] = [
        ["11111", "10001", "10011", "10101", "11001", "10001", "11111"],
        ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        ["11111", "00001", "00001", "11111", "10000", "10000", "11111"],
        ["11111", "00001", "00001", "01111", "00001", "00001", "11111"],
        ["10001", "10001", "10001", "11111", "00001", "00001", "00001"],
        ["11111", "10000", "10000", "11111", "00001", "00001", "11111"],
        ["11111", "10000", "10000", "11111", "10001", "10001", "11111"],
        ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        ["11111", "10001", "10001", "11111", "10001", "10001", "11111"],
        ["11111", "10001", "10001", "11111", "00001", "00001", "11111"]
    ]
    private static let colon = ["0", "1", "1", "0", "1", "1", "0"]

    static func pattern(
        for date: Date,
        calendar: Calendar = .current,
        colonOn: Bool = true
    ) -> [[Bool]] {
        let hour24 = calendar.component(.hour, from: date)
        let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
        let minute = calendar.component(.minute, from: date)
        let values = [hour / 10, hour % 10, minute / 10, minute % 10]
        var rows: [[Bool]] = []

        for row in 0..<7 {
            var bits: [String] = []
            for (index, value) in values.enumerated() {
                bits.append(digits[value][row])
                if index == 1 { bits.append(colonOn ? colon[row] : "0") }
            }
            rows.append(bits.joined(separator: "0").map { $0 == "1" })
        }
        return rows
    }
}

enum ClockGlyphs {
    // A deliberately coarse 3×5 bitmap face suited to a physical LED matrix.
    static let patterns: [[Bool]] = [
        bits("111101101101111"), bits("010110010010111"),
        bits("111001111100111"), bits("111001111001111"),
        bits("101101111001001"), bits("111100111001111"),
        bits("111100111101111"), bits("111001001001001"),
        bits("111101111101111"), bits("111101111001111")
    ]

    static func bits(_ value: String) -> [Bool] { value.map { $0 == "1" } }

    static func timeDigits(for date: Date, calendar: Calendar = .current) -> [Int] {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return [hour / 10, hour % 10, minute / 10, minute % 10]
    }

    static func isActive(digit: Int, at index: Int) -> Bool {
        guard patterns.indices.contains(digit), patterns[digit].indices.contains(index) else { return false }
        return patterns[digit][index]
    }

    static func hands(for digit: Int, at index: Int) -> (Double, Double) {
        guard isActive(digit: digit, at: index) else { return (225, 225) }
        let row = index / 3
        let column = index % 3
        let neighbors: [(Int, Int, Double)] = [(-1, 0, 0), (0, 1, 90), (1, 0, 180), (0, -1, 270)]
        let connected = neighbors.compactMap { dr, dc, angle -> Double? in
            let r = row + dr, c = column + dc
            guard (0..<5).contains(r), (0..<3).contains(c) else { return nil }
            return isActive(digit: digit, at: r * 3 + c) ? angle : nil
        }
        switch connected.count {
        case 0: return (45, 225)
        case 1: return (connected[0], connected[0] + 180)
        default: return (connected[0], connected[1])
        }
    }
}
