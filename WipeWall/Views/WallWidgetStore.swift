import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// The complete set of widgets that can be added from Wall's edit-mode picker.
/// Keep this list deliberately small: one useful instance of each kind can live
/// on the wall at a time.
enum WallWidgetKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case date
    case monthCalendar
    case dayProgress
    case yearProgress
    case battery
    case weatherDetails
    case subwayStatus
    case voiceAssistant
    case focusTimer
    case stopwatch
    case midnightCountdown
    case departureChecklist
    case wifiQRCode
    case moonPhase
    case worldTime
    case retardCounter
    // Strange shelf: appended deliberately so these always stay beneath the
    // original practical widgets in the picker.
    case weekStrip
    case threeMonths
    case weekNumber
    case dayOfYear
    case astrologicalWeather
    case mercuryMemo
    case lacanianSignifier
    case mirrorStage
    case desireOfOther
    case dreamResidue
    case defenseMechanism
    case projection
    case superegoForecast
    case strangeOracle
    case unreliableNarrator
    case dailyHoroscopes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "Today"
        case .monthCalendar: return "Month"
        case .dayProgress: return "Day progress"
        case .yearProgress: return "Year progress"
        case .battery: return "iPad battery"
        case .weatherDetails: return "Weather details"
        case .subwayStatus: return "Subway status"
        case .voiceAssistant: return "Sift + Sonos"
        case .focusTimer: return "Focus timer"
        case .stopwatch: return "Stopwatch"
        case .midnightCountdown: return "Until midnight"
        case .departureChecklist: return "Before you leave"
        case .wifiQRCode: return "Wi-Fi QR"
        case .moonPhase: return "Moon phase"
        case .worldTime: return "World time"
        case .retardCounter: return "retard counter"
        case .weekStrip: return "This week"
        case .threeMonths: return "Three months"
        case .weekNumber: return "Week number"
        case .dayOfYear: return "Day of year"
        case .astrologicalWeather: return "Astrological weather"
        case .mercuryMemo: return "Memo from Mercury"
        case .lacanianSignifier: return "Signifier of the day"
        case .mirrorStage: return "Mirror stage"
        case .desireOfOther: return "Desire of the Other"
        case .dreamResidue: return "Dream residue"
        case .defenseMechanism: return "Defense mechanism"
        case .projection: return "Today’s projection"
        case .superegoForecast: return "Superego forecast"
        case .strangeOracle: return "Strange oracle"
        case .unreliableNarrator: return "Unreliable narrator"
        case .dailyHoroscopes: return "Daily horoscopes"
        }
    }

    var detail: String {
        switch self {
        case .date: return "A large day and date"
        case .monthCalendar: return "The current month at a glance"
        case .dayProgress: return "How much of today has passed"
        case .yearProgress: return "How much of this year has passed"
        case .battery: return "Charge level and power state"
        case .weatherDetails: return "High, low, and rain chance"
        case .subwayStatus: return "Active L and M alerts"
        case .voiceAssistant: return "Private Sift connection status"
        case .focusTimer: return "A persistent 25-minute timer"
        case .stopwatch: return "A persistent elapsed-time clock"
        case .midnightCountdown: return "Time remaining in the day"
        case .departureChecklist: return "Keys, wallet, phone, headphones"
        case .wifiQRCode: return "A guest-ready code from the Wall note"
        case .moonPhase: return "Tonight's lunar phase"
        case .worldTime: return "New York, Los Angeles, and London"
        case .retardCounter: return "Counts exact matches heard near Wall"
        case .weekStrip: return "Seven days, with today underlined"
        case .threeMonths: return "Last, current, and next month"
        case .weekNumber: return "Your ISO week, unreasonably large"
        case .dayOfYear: return "Where today sits inside the year"
        case .astrologicalWeather: return "A tiny cosmic mood report"
        case .mercuryMemo: return "Questionable correspondence from a planet"
        case .lacanianSignifier: return "One floating signifier, lightly unmoored"
        case .mirrorStage: return "An amateur psychoanalytic mirror"
        case .desireOfOther: return "What the room imagines you want"
        case .dreamResidue: return "A generated fragment from last night"
        case .defenseMechanism: return "A playful mechanism of the moment"
        case .projection: return "What you may be putting on the furniture"
        case .superegoForecast: return "Internal weather, severe but unserious"
        case .strangeOracle: return "Tap for an unhelpfully precise omen"
        case .unreliableNarrator: return "A one-line rewrite of your day"
        case .dailyHoroscopes: return "Casey, Drew, Alex, Blake, and Ellis"
        }
    }

    var symbolName: String {
        switch self {
        case .date: return "calendar.day.timeline.left"
        case .monthCalendar: return "calendar"
        case .dayProgress: return "sun.max"
        case .yearProgress: return "circle.dashed"
        case .battery: return "battery.75"
        case .weatherDetails: return "cloud.sun"
        case .subwayStatus: return "tram"
        case .voiceAssistant: return "music.note.house"
        case .focusTimer: return "timer"
        case .stopwatch: return "stopwatch"
        case .midnightCountdown: return "moon.stars"
        case .departureChecklist: return "checklist"
        case .wifiQRCode: return "qrcode"
        case .moonPhase: return "moon"
        case .worldTime: return "globe.americas"
        case .retardCounter: return "number"
        case .weekStrip: return "calendar.badge.clock"
        case .threeMonths: return "calendar"
        case .weekNumber: return "number.square"
        case .dayOfYear: return "chart.bar.xaxis"
        case .astrologicalWeather: return "sparkles"
        case .mercuryMemo: return "paperplane"
        case .lacanianSignifier: return "textformat.abc"
        case .mirrorStage: return "circle.lefthalf.filled"
        case .desireOfOther: return "eye"
        case .dreamResidue: return "cloud.moon"
        case .defenseMechanism: return "shield.lefthalf.filled"
        case .projection: return "viewfinder"
        case .superegoForecast: return "exclamationmark.bubble"
        case .strangeOracle: return "wand.and.stars"
        case .unreliableNarrator: return "quote.bubble"
        case .dailyHoroscopes: return "sparkles"
        }
    }

    var baseSize: CGSize {
        switch self {
        case .date: return CGSize(width: 270, height: 132)
        case .monthCalendar: return CGSize(width: 292, height: 238)
        case .dayProgress, .yearProgress: return CGSize(width: 276, height: 126)
        case .battery: return CGSize(width: 220, height: 120)
        case .weatherDetails: return CGSize(width: 280, height: 150)
        case .subwayStatus: return CGSize(width: 336, height: 260)
        case .voiceAssistant: return CGSize(width: 236, height: 124)
        case .focusTimer: return CGSize(width: 244, height: 150)
        case .stopwatch: return CGSize(width: 244, height: 142)
        case .midnightCountdown: return CGSize(width: 268, height: 126)
        case .departureChecklist: return CGSize(width: 290, height: 218)
        case .wifiQRCode: return CGSize(width: 228, height: 256)
        case .moonPhase: return CGSize(width: 228, height: 174)
        case .worldTime: return CGSize(width: 276, height: 188)
        case .retardCounter: return CGSize(width: 220, height: 142)
        case .weekStrip: return CGSize(width: 360, height: 130)
        case .threeMonths: return CGSize(width: 390, height: 244)
        case .weekNumber, .dayOfYear: return CGSize(width: 250, height: 132)
        case .astrologicalWeather, .mercuryMemo, .lacanianSignifier,
             .mirrorStage, .desireOfOther, .dreamResidue, .defenseMechanism,
             .projection, .superegoForecast, .strangeOracle, .unreliableNarrator:
            return CGSize(width: 286, height: 160)
        case .dailyHoroscopes:
            return CGSize(width: 680, height: 590)
        }
    }
}

struct WallWidgetItem: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: WallWidgetKind
    var normalizedX: Double
    var normalizedY: Double
    var scale: Double
    var rotationDegrees: Double

    func center(in containerSize: CGSize) -> CGPoint {
        let halfWidth = min(kind.baseSize.width * CGFloat(scale) / 2, containerSize.width / 2)
        let halfHeight = min(kind.baseSize.height * CGFloat(scale) / 2, containerSize.height / 2)
        return CGPoint(
            x: min(
                max(CGFloat(normalizedX) * containerSize.width, halfWidth),
                max(halfWidth, containerSize.width - halfWidth)
            ),
            y: min(
                max(CGFloat(normalizedY) * containerSize.height, halfHeight),
                max(halfHeight, containerSize.height - halfHeight)
            )
        )
    }

    func contains(_ point: CGPoint, in containerSize: CGSize, controlPadding: CGFloat = 34) -> Bool {
        let center = center(in: containerSize)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radians = CGFloat(rotationDegrees * .pi / 180)
        let localX = dx * cos(radians) + dy * sin(radians)
        let localY = -dx * sin(radians) + dy * cos(radians)
        let halfWidth = kind.baseSize.width * CGFloat(scale) / 2 + controlPadding
        let halfHeight = kind.baseSize.height * CGFloat(scale) / 2 + controlPadding
        return abs(localX) <= halfWidth && abs(localY) <= halfHeight
    }
}

/// Owns the user's chosen widget instances and every persisted edit transform.
/// Array order is the stacking order: the final item is visually on top.
final class WallWidgetStore: ObservableObject {
    // The legacy raw value remains migration-safe, but its content is now the
    // read-only Sift connection widget instead of a manual mic button.
    static let catalog = WallWidgetKind.allCases

    @Published private(set) var items: [WallWidgetItem] = []
    @Published var selectedID: UUID?
    private(set) var lastControlInteraction = Date.distantPast

    private let defaults: UserDefaults
    private let persistenceKey: String

    init(defaults: UserDefaults = .standard, persistenceKey: String = "wall.widgets.v1") {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        restore()
    }

    func cloudSnapshotData() -> Data? {
        try? JSONEncoder().encode(items)
    }

    func applyCloudSnapshotData(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([WallWidgetItem].self, from: data) else { return }
        items = decoded
        selectedID = nil
        persist()
    }

    func contains(_ kind: WallWidgetKind) -> Bool {
        items.contains { $0.kind == kind }
    }

    @discardableResult
    func add(_ kind: WallWidgetKind, in containerSize: CGSize) -> UUID {
        if let existing = items.first(where: { $0.kind == kind }) {
            selectedID = existing.id
            return existing.id
        }

        let positions: [(Double, Double)] = [
            (0.50, 0.50), (0.34, 0.42), (0.66, 0.42),
            (0.34, 0.62), (0.66, 0.62), (0.50, 0.30)
        ]
        let suggested = positions[items.count % positions.count]
        let center = clampedCenter(
            CGPoint(
                x: CGFloat(suggested.0) * max(containerSize.width, 1),
                y: CGFloat(suggested.1) * max(containerSize.height, 1)
            ),
            kind: kind,
            scale: 1,
            in: containerSize
        )
        let item = WallWidgetItem(
            id: UUID(),
            kind: kind,
            normalizedX: Double(center.x / max(containerSize.width, 1)),
            normalizedY: Double(center.y / max(containerSize.height, 1)),
            scale: 1,
            rotationDegrees: 0
        )
        items.append(item)
        selectedID = item.id
        persist()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return item.id
    }

    func update(_ id: UUID, center: CGPoint, scale: CGFloat, rotation: Angle, in containerSize: CGSize) {
        guard let index = index(for: id) else { return }
        let clampedScale = min(max(scale, 0.45), 3)
        let clampedCenter = clampedCenter(
            center,
            kind: items[index].kind,
            scale: clampedScale,
            in: containerSize
        )
        items[index].normalizedX = Double(clampedCenter.x / max(containerSize.width, 1))
        items[index].normalizedY = Double(clampedCenter.y / max(containerSize.height, 1))
        items[index].scale = Double(clampedScale)
        items[index].rotationDegrees = rotation.degrees
        persist()
    }

    func remove(_ id: UUID) {
        guard let index = index(for: id) else { return }
        items.remove(at: index)
        if selectedID == id { selectedID = nil }
        persist()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func snapRotation(_ id: UUID) {
        lastControlInteraction = Date()
        guard let index = index(for: id) else { return }
        items[index].rotationDegrees = Self.closestSnapAngle(to: items[index].rotationDegrees)
        persist()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func sendToBack(_ id: UUID) {
        lastControlInteraction = Date()
        move(id, toFront: false)
    }

    func bringToFront(_ id: UUID) {
        lastControlInteraction = Date()
        move(id, toFront: true)
    }

    func zIndex(for id: UUID) -> Double {
        Double(items.firstIndex(where: { $0.id == id }) ?? 0)
    }

    func deselect() {
        selectedID = nil
    }

    func dismissSelectionIfTappedOutside(_ point: CGPoint, in containerSize: CGSize) {
        guard let selectedID,
              let item = items.first(where: { $0.id == selectedID }),
              !item.contains(point, in: containerSize) else { return }
        self.selectedID = nil
    }

    @discardableResult
    func selectTopmost(at point: CGPoint, in containerSize: CGSize) -> Bool {
        guard let item = items.reversed().first(where: { $0.contains(point, in: containerSize) }) else {
            return false
        }
        selectedID = item.id
        return true
    }

    func contains(_ id: UUID, point: CGPoint, in containerSize: CGSize) -> Bool {
        items.first(where: { $0.id == id })?.contains(point, in: containerSize) == true
    }

    static func closestSnapAngle(to degrees: Double) -> Double {
        let snapAngles = [0.0, 45.0, 90.0, 135.0, 180.0]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return snapAngles.min {
            circularDistance(normalized, $0) < circularDistance(normalized, $1)
        } ?? 0
    }

    private func restore() {
        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([WallWidgetItem].self, from: data) else {
            items = []
            return
        }

        // Keep only the first valid instance of each known kind. This also
        // makes old/corrupt metadata harmless if the catalog evolves.
        var kinds = Set<WallWidgetKind>()
        items = decoded.filter { item in
            guard !kinds.contains(item.kind), item.scale.isFinite,
                  item.normalizedX.isFinite, item.normalizedY.isFinite,
                  item.rotationDegrees.isFinite else { return false }
            kinds.insert(item.kind)
            return true
        }
        if items != decoded { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private func index(for id: UUID) -> Int? {
        items.firstIndex(where: { $0.id == id })
    }

    private func move(_ id: UUID, toFront: Bool) {
        guard let current = index(for: id), !items.isEmpty else { return }
        let destination = toFront ? items.count - 1 : 0
        guard destination != current else { return }
        let item = items.remove(at: current)
        items.insert(item, at: toFront ? items.endIndex : items.startIndex)
        persist()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func clampedCenter(
        _ point: CGPoint,
        kind: WallWidgetKind,
        scale: CGFloat,
        in containerSize: CGSize
    ) -> CGPoint {
        let halfWidth = min(kind.baseSize.width * scale / 2, containerSize.width / 2)
        let halfHeight = min(kind.baseSize.height * scale / 2, containerSize.height / 2)
        return CGPoint(
            x: min(max(point.x, halfWidth), max(halfWidth, containerSize.width - halfWidth)),
            y: min(max(point.y, halfHeight), max(halfHeight, containerSize.height - halfHeight))
        )
    }

    private static func circularDistance(_ first: Double, _ second: Double) -> Double {
        let distance = abs(first - second)
        return min(distance, 360 - distance)
    }
}
