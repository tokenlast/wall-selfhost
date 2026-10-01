import SwiftUI

struct MTARouteAppearance: Equatable {
    let label: String
    let backgroundHex: UInt32
    let usesDarkLettering: Bool

    static func forRoute(_ rawRoute: String) -> MTARouteAppearance {
        let route = rawRoute
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let baseRoute = route.replacingOccurrences(
            of: #"[^A-Z0-9]"#,
            with: "",
            options: .regularExpression
        )

        switch baseRoute {
        case "1", "2", "3", "1X", "2X", "3X":
            return MTARouteAppearance(label: String(baseRoute.prefix(1)), backgroundHex: 0xD82233, usesDarkLettering: false)
        case "4", "5", "6", "4X", "5X", "6X":
            return MTARouteAppearance(label: String(baseRoute.prefix(1)), backgroundHex: 0x009952, usesDarkLettering: false)
        case "7", "7X":
            return MTARouteAppearance(label: "7", backgroundHex: 0x9A38A1, usesDarkLettering: false)
        case "A", "C", "E":
            return MTARouteAppearance(label: baseRoute, backgroundHex: 0x0062CF, usesDarkLettering: false)
        case "B", "D", "F", "M":
            return MTARouteAppearance(label: baseRoute, backgroundHex: 0xEB6800, usesDarkLettering: false)
        case "G":
            return MTARouteAppearance(label: baseRoute, backgroundHex: 0x799534, usesDarkLettering: false)
        case "J", "Z":
            return MTARouteAppearance(label: baseRoute, backgroundHex: 0x8E5C33, usesDarkLettering: false)
        case "L":
            return MTARouteAppearance(label: baseRoute, backgroundHex: 0x7C858C, usesDarkLettering: false)
        case "N", "Q", "R", "W":
            return MTARouteAppearance(label: baseRoute, backgroundHex: 0xF6BC26, usesDarkLettering: true)
        case "SI", "SIR":
            return MTARouteAppearance(label: "SIR", backgroundHex: 0x0078C6, usesDarkLettering: false)
        case "S", "FS", "GS", "H":
            return MTARouteAppearance(label: "S", backgroundHex: 0x7C858C, usesDarkLettering: false)
        default:
            return MTARouteAppearance(label: baseRoute.isEmpty ? "?" : baseRoute, backgroundHex: 0x7C858C, usesDarkLettering: false)
        }
    }
}

struct MTARouteBullet: View {
    let route: String
    var diameter: CGFloat = 24

    private var appearance: MTARouteAppearance {
        MTARouteAppearance.forRoute(route)
    }

    var body: some View {
        Text(appearance.label)
            .font(.custom("Helvetica-Bold", size: appearance.label.count > 1 ? diameter * 0.36 : diameter * 0.58))
            .foregroundColor(appearance.usesDarkLettering ? .black : .white)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .frame(width: diameter, height: diameter)
            .background(Color(mtaHex: appearance.backgroundHex))
            .clipShape(Circle())
            .accessibilityLabel("\(appearance.label) train")
    }
}

struct MTARouteBulletStrip: View {
    let routes: [String]
    var diameter: CGFloat = 24

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
                MTARouteBullet(route: route, diameter: diameter)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct TransitTickerView: View {
    let alerts: [TransitAlert]

    var body: some View {
        TransitAlertList(
            alerts: WallTransitScope.alerts(from: alerts),
            bulletDiameter: 20,
            fontSize: 12,
            rowHeight: 26
        )
    }
}

struct TransitAlertList: View {
    let alerts: [TransitAlert]
    var bulletDiameter: CGFloat = 20
    var fontSize: CGFloat = 12
    var rowHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(alerts) { alert in
                HStack(alignment: .center, spacing: 8) {
                    MTARouteBulletStrip(routes: alert.routes, diameter: bulletDiameter)
                    Text(alert.headline)
                        .font(.custom("Helvetica", size: fontSize))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Subway alert. \(alert.routes.joined(separator: ", ")). \(alert.headline)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private extension Color {
    init(mtaHex: UInt32) {
        self.init(
            red: Double((mtaHex >> 16) & 0xFF) / 255,
            green: Double((mtaHex >> 8) & 0xFF) / 255,
            blue: Double(mtaHex & 0xFF) / 255
        )
    }
}
