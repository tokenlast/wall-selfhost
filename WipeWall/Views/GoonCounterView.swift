import AVFoundation
import SwiftUI

enum GoonPerson: String, CaseIterable, Identifiable, Codable {
    case alex
    case blake
    case casey
    case drew
    case ellis

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .alex: return Color(red: 1, green: 0.23, blue: 0.55)
        case .blake: return Color(red: 1, green: 0.48, blue: 0)
        case .casey: return Color(red: 0.10, green: 0.45, blue: 0.91)
        case .drew: return Color(red: 0, green: 0.66, blue: 0.42)
        case .ellis: return Color(red: 0.56, green: 0.27, blue: 0.68)
        }
    }
}

final class GoonCounterModel: ObservableObject {
    @Published private(set) var counts: [GoonPerson: Int] = [:]
    @Published private(set) var celebration: GoonCelebration?
    @Published var isIdentityPickerPresented = false

    private let defaults: UserDefaults
    private let persistenceKey: String
    private let eventRecorder: GoonEventRecording?
    private let now: () -> Date
    private var recentIncrementDates: [Date] = []

    // The tally sheet has enough visual feedback and reordering that two
    // seconds was too easy to miss in normal use. Five seconds still reads as
    // one quick +3 gesture while making the celebration dependable.
    static let rapidIncrementWindow: TimeInterval = 5

    init(
        defaults: UserDefaults = .standard,
        persistenceKey: String = "wall.goon.counts.v1",
        eventRecorder: GoonEventRecording? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        self.eventRecorder = eventRecorder
        self.now = now
        if let saved = defaults.dictionary(forKey: persistenceKey) as? [String: Int] {
            counts = Dictionary(uniqueKeysWithValues: GoonPerson.allCases.map { ($0, saved[$0.rawValue] ?? 0) })
        } else {
            counts = Dictionary(uniqueKeysWithValues: GoonPerson.allCases.map { ($0, 0) })
        }
    }

    func increment(_ person: GoonPerson) {
        let occurredAt = now()
        counts[person, default: 0] += 1
        persist()
        eventRecorder?.record(GoonLogEvent(id: UUID(), person: person, action: .add, occurredAt: occurredAt))
        recentIncrementDates = recentIncrementDates.filter {
            let elapsed = occurredAt.timeIntervalSince($0)
            return elapsed >= 0 && elapsed <= Self.rapidIncrementWindow
        }
        recentIncrementDates.append(occurredAt)
        let isRapidTriple = recentIncrementDates.count >= 3
        if isRapidTriple { recentIncrementDates.removeAll(keepingCapacity: true) }
        if isRapidTriple && celebration?.style != .rapidTriple {
            celebration = GoonCelebration(person: person, style: .rapidTriple)
        } else if celebration?.style != .rapidTriple {
            // Once the five-second combo begins, later ordinary taps must not
            // replace it with the much shorter single-point splash.
            celebration = GoonCelebration(person: person, style: .splash)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func decrement(_ person: GoonPerson) {
        guard counts[person, default: 0] > 0 else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        counts[person, default: 0] -= 1
        persist()
        eventRecorder?.record(GoonLogEvent(id: UUID(), person: person, action: .remove, occurredAt: Date()))
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    func finishCelebration(_ id: UUID) {
        guard celebration?.id == id else { return }
        celebration = nil
    }

    var rankedPeople: [GoonPerson] {
        let originalOrder = Dictionary(
            uniqueKeysWithValues: GoonPerson.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        return GoonPerson.allCases.sorted { first, second in
            let firstCount = counts[first, default: 0]
            let secondCount = counts[second, default: 0]
            if firstCount != secondCount { return firstCount > secondCount }
            return originalOrder[first, default: 0] < originalOrder[second, default: 0]
        }
    }

    private func persist() {
        defaults.set(
            Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }),
            forKey: persistenceKey
        )
    }
}

enum GoonCelebrationStyle: Equatable {
    case splash
    case rapidTriple
}

struct GoonCelebration: Identifiable, Equatable {
    let id: UUID
    let person: GoonPerson
    let style: GoonCelebrationStyle

    init(id: UUID = UUID(), person: GoonPerson, style: GoonCelebrationStyle = .splash) {
        self.id = id
        self.person = person
        self.style = style
    }
}

struct GoonCounterView: View {
    @ObservedObject var model: GoonCounterModel
    let onControlInteraction: () -> Void

    init(
        model: GoonCounterModel,
        onControlInteraction: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onControlInteraction = onControlInteraction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("GOON COUNTER")
                    .font(.custom("Helvetica", size: 13).weight(.bold))
                    .tracking(0.6)
                    .allowsHitTesting(false)

                Spacer()

                Button(action: {
                    onControlInteraction()
                    model.isIdentityPickerPresented = true
                }) {
                    Text("😩")
                        .font(.system(size: 23))
                        .frame(width: 42, height: 42)
                        .background(Color.black)
                        .cornerRadius(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GoonCounterPressStyle())
                .accessibilityLabel("Adjust goon tallies")
                .accessibilityIdentifier("wall.goon.add")
            }

            Rectangle().fill(Color.black).frame(height: 1).allowsHitTesting(false)

            VStack(spacing: 7) {
                ForEach(model.rankedPeople) { person in
                    HStack(spacing: 8) {
                        AnimatedGoonName(person: person)
                            .frame(width: 88, alignment: .leading)
                            .allowsHitTesting(false)

                        TallyMarksView(count: model.counts[person, default: 0], color: person.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)

                        Text("\(model.counts[person, default: 0])")
                            .font(.custom("Helvetica", size: 13).weight(.bold))
                            .foregroundColor(person.color)
                            .frame(minWidth: 24, alignment: .trailing)
                            .accessibilityIdentifier("wall.goon.count.\(person.rawValue)")
                            .allowsHitTesting(false)

                    }
                    .frame(height: 24)
                }
            }
        }
        .padding(12)
    }

}

/// Lives in Wall's own overlay stack, below celebrations. A UIKit popover
/// otherwise hides the full-screen effect no matter how high its zIndex is.
struct GoonIdentityOverlay: View {
    @ObservedObject var model: GoonCounterModel
    let onIncrement: () -> Void

    init(model: GoonCounterModel, onIncrement: @escaping () -> Void = {}) {
        self.model = model
        self.onIncrement = onIncrement
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture { model.isIdentityPickerPresented = false }
            identityMenu
                .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
        }
        .wallAutoDismissModal { model.isIdentityPickerPresented = false }
    }

    private var identityMenu: some View {
        GoonIdentityMenu(
            counts: model.counts,
            onIncrement: { person in
                model.increment(person)
                onIncrement()
            },
            onDecrement: { person in
                model.decrement(person)
            }
        )
    }
}

/// Serializes the deliberately noisy counter feedback so rapid taps still
/// produce one complete sound followed by one capture request per point.
@MainActor
final class GoonIncrementEffectController: ObservableObject {
    private var pendingCaptures: [() -> Void] = []
    private var player: AVAudioPlayer?
    private var isPlaying = false

    func playThenCapture(_ capture: @escaping () -> Void) {
        pendingCaptures.append(capture)
        playNextIfNeeded()
    }

    private func playNextIfNeeded() {
        guard !isPlaying, !pendingCaptures.isEmpty else { return }
        isPlaying = true
        let capture = pendingCaptures.removeFirst()

        do {
            let nextPlayer = try GoonMoanSound.makePlayer()
            nextPlayer.volume = 1
            nextPlayer.prepareToPlay()
            player = nextPlayer
            let duration = max(0.1, nextPlayer.duration)
            guard nextPlayer.play() else {
                capture()
                finishCurrentSound()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + GoonMoanSound.captureDelay) {
                capture()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.finishCurrentSound()
            }
        } catch {
            capture()
            finishCurrentSound()
        }
    }

    private func finishCurrentSound() {
        player?.stop()
        player = nil
        isPlaying = false
        playNextIfNeeded()
    }
}

enum GoonMoanSound {
    static let resourceName = "579256__bluedeer__animemoan"
    static let captureDelay: TimeInterval = 1

    static func resourceURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: "mp3")
    }

    static func makePlayer(in bundle: Bundle = .main) throws -> AVAudioPlayer {
        guard let url = resourceURL(in: bundle) else {
            throw NSError(
                domain: "Wall.GoonMoanSound",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The bundled goon-counter sound is missing."]
            )
        }
        return try AVAudioPlayer(contentsOf: url)
    }
}

private struct GoonCounterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}

private struct GoonIdentityMenu: View {
    let counts: [GoonPerson: Int]
    let onIncrement: (GoonPerson) -> Void
    let onDecrement: (GoonPerson) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ADJUST GOON COUNTER")
                .font(.custom("Helvetica", size: 12).weight(.bold))
                .tracking(0.6)
                .padding(.horizontal, 14)
                .frame(height: 38)

            Rectangle().fill(Color.black).frame(height: 1)

            ForEach(GoonPerson.allCases) { person in
                GoonIdentityRow(
                    person: person,
                    count: counts[person, default: 0],
                    onIncrement: { onIncrement(person) },
                    onDecrement: { onDecrement(person) }
                )
            }
        }
        .frame(width: 292)
        .background(Color.white)
    }
}

private struct GoonIdentityRow: View {
    let person: GoonPerson
    let count: Int
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(person.rawValue)
                .font(.custom("Helvetica", size: 17).weight(.bold))
                .foregroundColor(person.color)

            Spacer()

            Text("\(count)")
                .font(.custom("Helvetica", size: 14).weight(.bold))
                .foregroundColor(person.color)
                .frame(minWidth: 24, alignment: .trailing)
                .accessibilityHidden(true)

            menuButton(
                symbol: "minus",
                label: "Remove one from \(person.rawValue)",
                identifier: "wall.goon.menu.minus.\(person.rawValue)",
                action: onDecrement
            )

            menuButton(
                symbol: "plus",
                label: "Add one to \(person.rawValue)",
                identifier: "wall.goon.menu.plus.\(person.rawValue)",
                action: onIncrement
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color.white)
    }

    private func menuButton(
        symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(GoonCounterPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

struct GoonSplashCelebration: View {
    let celebration: GoonCelebration
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var isFading = false

    private let columns = 7
    private let rows = 6

    @ViewBuilder
    var body: some View {
        switch celebration.style {
        case .splash:
            GeometryReader { proxy in
                ZStack {
                    ForEach(0..<(columns * rows), id: \.self) { index in
                        Text("💦")
                            .font(.system(size: emojiSize(in: proxy.size)))
                            .rotationEffect(.degrees(rotation(for: index)))
                            .scaleEffect(scale(for: index))
                            .opacity(isVisible && !isFading ? 1 : 0)
                            .position(position(for: index, in: proxy.size))
                            .animation(entranceAnimation(for: index), value: isVisible)
                            .animation(.easeIn(duration: 0.34), value: isFading)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear(perform: runAnimation)
        case .rapidTriple:
            GoonRapidTripleCelebration(onFinished: onFinished)
        }
    }

    private func runAnimation() {
        isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.48 : 0.72)) {
            isFading = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.82 : 1.15)) {
            onFinished()
        }
    }

    private func entranceAnimation(for index: Int) -> Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.16) }
        return .spring(response: 0.28, dampingFraction: 0.66)
            .delay(Double(index % 9) * 0.012)
    }

    private func emojiSize(in size: CGSize) -> CGFloat {
        min(122, max(62, size.width / CGFloat(columns) * 0.72))
    }

    private func position(for index: Int, in size: CGSize) -> CGPoint {
        let column = index % columns
        let row = index / columns
        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)
        let horizontalNudge = CGFloat((index * 29) % 31 - 15) * 0.42
        let verticalNudge = CGFloat((index * 17) % 27 - 13) * 0.38
        return CGPoint(
            x: (CGFloat(column) + 0.5) * cellWidth + horizontalNudge,
            y: (CGFloat(row) + 0.5) * cellHeight + verticalNudge
        )
    }

    private func rotation(for index: Int) -> Double {
        Double((index * 37) % 50 - 25)
    }

    private func scale(for index: Int) -> CGFloat {
        guard isVisible else { return reduceMotion ? 1 : 0.08 }
        if isFading { return reduceMotion ? 1 : 1.28 }
        return 0.84 + CGFloat(index % 5) * 0.08
    }
}

struct GoonRapidTripleAnimationPolicy {
    static let phaseCount = 10
    static let phaseDuration: TimeInterval = 0.5

    static func emoji(for phase: Int) -> String {
        phase.isMultiple(of: 2) ? "🍆" : "🍑"
    }
}

private struct GoonRapidTripleCelebration: View {
    let onFinished: () -> Void

    @State private var phase = 0
    @State private var animationTask: Task<Void, Never>?

    private let columns = 8
    private let rows = 6

    var body: some View {
        GeometryReader { proxy in
            let emoji = GoonRapidTripleAnimationPolicy.emoji(for: phase)
            ZStack {
                ForEach(0..<(columns * rows), id: \.self) { index in
                    Text(emoji)
                        .font(.system(size: backgroundEmojiSize(in: proxy.size)))
                        .rotationEffect(.degrees(Double((index * 31) % 42 - 21)))
                        .scaleEffect(0.78 + CGFloat(index % 4) * 0.1)
                        .position(position(for: index, in: proxy.size))
                }

                Text(emoji)
                    .font(.system(size: giantEmojiSize(in: proxy.size)))
                    .shadow(color: .white, radius: 14)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .zIndex(1)
                    .accessibilityIdentifier("wall.goon.combo.phase")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear(perform: startAnimation)
        .onDisappear { animationTask?.cancel() }
    }

    private func startAnimation() {
        animationTask?.cancel()
        phase = 0
        animationTask = Task { @MainActor in
            for nextPhase in 1..<GoonRapidTripleAnimationPolicy.phaseCount {
                try? await Task.sleep(
                    nanoseconds: UInt64(GoonRapidTripleAnimationPolicy.phaseDuration * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                phase = nextPhase
            }
            try? await Task.sleep(
                nanoseconds: UInt64(GoonRapidTripleAnimationPolicy.phaseDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }

    private func giantEmojiSize(in size: CGSize) -> CGFloat {
        min(430, max(250, min(size.width, size.height) * 0.52))
    }

    private func backgroundEmojiSize(in size: CGSize) -> CGFloat {
        min(105, max(58, size.width / CGFloat(columns) * 0.62))
    }

    private func position(for index: Int, in size: CGSize) -> CGPoint {
        let column = index % columns
        let row = index / columns
        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)
        let horizontalNudge = CGFloat((index * 19) % 25 - 12) * 0.6
        let verticalNudge = CGFloat((index * 23) % 29 - 14) * 0.5
        return CGPoint(
            x: (CGFloat(column) + 0.5) * cellWidth + horizontalNudge,
            y: (CGFloat(row) + 0.5) * cellHeight + verticalNudge
        )
    }
}

struct AnimatedGoonName: View {
    let person: GoonPerson

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.14)) { context in
            animatedContent(time: context.date.timeIntervalSinceReferenceDate)
        }
        .font(.custom("Helvetica", size: 16).weight(.bold))
        .lineLimit(1)
    }

    @ViewBuilder
    private func animatedContent(time: TimeInterval) -> some View {
        switch person {
        case .alex:
            Text(unicodeShifted(person.rawValue, tick: Int(time * 3)))
                .foregroundColor(person.color)
        case .blake:
            Text(person.rawValue)
                .foregroundStyle(
                    LinearGradient(
                        colors: [person.color, .yellow, .pink, .purple, person.color],
                        startPoint: UnitPoint(x: (time.truncatingRemainder(dividingBy: 2.4) / 2.4) - 0.7, y: 0),
                        endPoint: UnitPoint(x: (time.truncatingRemainder(dividingBy: 2.4) / 2.4) + 0.3, y: 1)
                    )
                )
        case .casey:
            Text(person.rawValue)
                .foregroundColor(person.color)
                .opacity(time.truncatingRemainder(dividingBy: 1.35) < 0.84 ? 1 : 0.12)
        case .drew:
            animatedLetters(time: time, falling: true)
        case .ellis:
            animatedLetters(time: time, falling: false)
        }
    }

    private func animatedLetters(time: TimeInterval, falling: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(person.rawValue.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .foregroundColor(person.color)
                    .offset(y: letterOffset(index: index, time: time, falling: falling))
            }
        }
        .frame(height: 22)
        .clipped()
    }

    private func letterOffset(index: Int, time: TimeInterval, falling: Bool) -> CGFloat {
        if falling {
            let phase = (time + Double(index) * 0.22).truncatingRemainder(dividingBy: 7.5)
            if phase > 2.15 && phase < 3.7 { return 18 }
            if phase >= 3.7 && phase < 4.5 { return -18 }
            return 0
        }
        return sin(time * 4.2 + Double(index) * 0.9) * 2.5
    }

    private func unicodeShifted(_ value: String, tick: Int) -> String {
        let boldUpper = 0x1D400
        let sansUpper = 0x1D5D4
        let fullUpper = 0xFF21
        let circledUpper = 0x24B6
        let boldLower = 0x1D41A
        let sansLower = 0x1D5EE
        let fullLower = 0xFF41
        let circledLower = 0x24D0
        let upperStyles = [boldUpper, sansUpper, fullUpper, circledUpper]
        let lowerStyles = [boldLower, sansLower, fullLower, circledLower]

        return String(value.enumerated().map { index, character in
            guard let scalar = character.unicodeScalars.first else { return character }
            let code = Int(scalar.value)
            let style = (tick + index) % 4
            if (65...90).contains(code), let shifted = UnicodeScalar(upperStyles[style] + code - 65) {
                return Character(String(shifted))
            }
            if (97...122).contains(code), let shifted = UnicodeScalar(lowerStyles[style] + code - 97) {
                return Character(String(shifted))
            }
            return character
        })
    }
}

private struct TallyMarksView: View {
    let count: Int
    let color: Color

    var body: some View {
        if count == 0 {
            Text("—")
                .font(.custom("Helvetica", size: 14))
                .foregroundColor(color.opacity(0.35))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(0..<Int(ceil(Double(count) / 5.0)), id: \.self) { group in
                        TallyGroup(markCount: min(5, count - group * 5), color: color)
                    }
                }
            }
        }
    }
}

private struct TallyGroup: View {
    let markCount: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1.6, lineCap: .round)
            for index in 0..<min(markCount, 4) {
                let x = CGFloat(index) * 4 + 2
                var line = Path()
                line.move(to: CGPoint(x: x, y: 2))
                line.addLine(to: CGPoint(x: x, y: size.height - 2))
                context.stroke(line, with: .color(color), style: stroke)
            }
            if markCount == 5 {
                var slash = Path()
                slash.move(to: CGPoint(x: 0, y: size.height - 3))
                slash.addLine(to: CGPoint(x: 16, y: 3))
                context.stroke(slash, with: .color(color), style: stroke)
            }
        }
        .frame(width: 17, height: 18)
    }
}
