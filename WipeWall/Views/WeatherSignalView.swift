import SwiftUI

struct WeatherSignalView: View {
    let snapshot: WeatherSnapshot?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                if let snapshot {
                    ZStack {
                        if snapshot.expectsRain {
                            UmbrellaShape()
                                .stroke(Color.black, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .offset(y: reduceMotion ? 0 : (floating ? -4 : 4))
                                .animation(
                                    reduceMotion ? .none : .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                                    value: floating
                                )
                                .onAppear { floating = true }
                        } else {
                            SunShape()
                                .stroke(Color.black, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }

                        Text("\(Int(snapshot.currentTemperature.rounded()))°")
                            .font(.custom("Helvetica-Bold", size: 12))
                            .padding(.horizontal, 1)
                            .background(Color.white)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Int(snapshot.high.rounded()))° / \(Int(snapshot.low.rounded()))°")
                            .font(.custom("Helvetica", size: 16))
                        Text("\(WeatherCodePresentation.label(for: snapshot.currentCode)) · \(snapshot.rainChance)% rain today")
                            .font(.custom("Helvetica", size: 10))
                    }
                    .foregroundColor(.black)
                }
            }

            if let periods = snapshot?.periods, !periods.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(periods) { period in
                        WeatherPeriodView(period: period)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct WeatherPeriodView: View {
    let period: WeatherPeriod

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "ha"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            Text(Self.timeFormatter.string(from: period.time).lowercased())
                .font(.custom("Helvetica", size: 8))
            Image(systemName: WeatherCodePresentation.symbol(for: period.weatherCode))
                .font(.system(size: 11, weight: .regular))
                .frame(height: 12)
            HStack(spacing: 3) {
                Text("\(period.rainChance)%")
                    .font(.custom("Helvetica-Bold", size: 8))
                Text("\(Int(period.temperature.rounded()))°")
                    .font(.custom("Helvetica", size: 8))
            }
        }
        .foregroundColor(.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.timeFormatter.string(from: period.time)), \(WeatherCodePresentation.label(for: period.weatherCode)), \(period.rainChance) percent rain, \(Int(period.temperature.rounded())) degrees")
    }
}

struct SunShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.22
        path.addEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        for angle in stride(from: 0.0, to: 360.0, by: 45.0) {
            let radians = angle * .pi / 180
            let inner = radius * 1.45
            let outer = radius * 2
            path.move(to: CGPoint(
                x: center.x + CGFloat(cos(radians)) * inner,
                y: center.y + CGFloat(sin(radians)) * inner
            ))
            path.addLine(to: CGPoint(
                x: center.x + CGFloat(cos(radians)) * outer,
                y: center.y + CGFloat(sin(radians)) * outer
            ))
        }
        return path
    }
}

struct UmbrellaShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = CGPoint(x: rect.minX + 2, y: rect.midY * 0.86)
        let right = CGPoint(x: rect.maxX - 2, y: rect.midY * 0.86)
        let center = CGPoint(x: rect.midX, y: rect.midY * 0.86)

        path.move(to: left)
        path.addQuadCurve(to: right, control: CGPoint(x: rect.midX, y: rect.minY - 5))
        path.addQuadCurve(to: CGPoint(x: center.x + rect.width * 0.18, y: center.y), control: CGPoint(x: center.x + rect.width * 0.28, y: center.y - 6))
        path.addQuadCurve(to: center, control: CGPoint(x: center.x + rect.width * 0.08, y: center.y - 5))
        path.addQuadCurve(to: CGPoint(x: center.x - rect.width * 0.18, y: center.y), control: CGPoint(x: center.x - rect.width * 0.08, y: center.y - 5))
        path.addQuadCurve(to: left, control: CGPoint(x: center.x - rect.width * 0.28, y: center.y - 6))

        path.move(to: center)
        path.addLine(to: CGPoint(x: center.x, y: rect.maxY - 8))
        path.addQuadCurve(
            to: CGPoint(x: center.x - 8, y: rect.maxY - 4),
            control: CGPoint(x: center.x, y: rect.maxY + 2)
        )
        return path
    }
}
