import SwiftUI

enum InkColor: String, Codable, CaseIterable, Identifiable {
    case black, red, blue, green, orange, purple

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .black: return .black
        case .red: return Color(red: 0.82, green: 0.08, blue: 0.08)
        case .blue: return Color(red: 0.06, green: 0.25, blue: 0.82)
        case .green: return Color(red: 0.05, green: 0.48, blue: 0.20)
        case .orange: return Color(red: 0.94, green: 0.35, blue: 0.03)
        case .purple: return Color(red: 0.48, green: 0.12, blue: 0.68)
        }
    }
}

fileprivate struct InkPoint: Codable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

fileprivate struct InkStroke: Identifiable, Codable {
    let id: UUID
    var points: [InkPoint]
    let color: InkColor

    private enum CodingKeys: String, CodingKey { case id, points, color }

    init(points: [InkPoint], color: InkColor) {
        id = UUID()
        self.points = points
        self.color = color
    }
}

final class InkCanvasModel: ObservableObject {
    @Published fileprivate var strokes: [InkStroke] = []
    @Published private(set) var isErasing = false
    @Published private(set) var isPaletteExpanded = false
    @Published private(set) var isDrawingEnabled = false
    @Published private(set) var selectedColor: InkColor = .black

    private let eraserRadius: CGFloat = 26
    private let persistenceURL: URL?
    private let onPersist: (() -> Void)?
    private var activeStrokeID: UUID?
    private var gestureIsActive = false
    private var history: [[InkStroke]] = []
    private var eraserResetWorkItem: DispatchWorkItem?
    private var paletteResetWorkItem: DispatchWorkItem?

    var canUndo: Bool { !history.isEmpty }
    var visibleStrokeCount: Int { strokes.count }

    func cloudSnapshotData() -> Data? {
        try? JSONEncoder().encode(strokes)
    }

    func applyCloudSnapshotData(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([InkStroke].self, from: data) else { return }
        strokes = decoded
        history.removeAll()
        activeStrokeID = nil
        gestureIsActive = false
        persist()
    }

    init(
        persistenceURL: URL? = InkCanvasModel.defaultPersistenceURL,
        onPersist: (() -> Void)? = nil
    ) {
        self.persistenceURL = persistenceURL
        self.onPersist = onPersist
        restore()
    }

    func appendPoint(_ point: CGPoint) {
        guard isDrawingEnabled else { return }
        expandPalette()
        beginGestureIfNeeded()

        if isErasing {
            eraserResetWorkItem?.cancel()
            strokes.removeAll { stroke in
                stroke.points.contains { distance($0.cgPoint, point) <= eraserRadius }
            }
        } else if let activeStrokeID,
                  let index = strokes.firstIndex(where: { $0.id == activeStrokeID }) {
            strokes[index].points.append(InkPoint(point))
        } else {
            let stroke = InkStroke(points: [InkPoint(point)], color: selectedColor)
            strokes.append(stroke)
            activeStrokeID = stroke.id
        }
    }

    func endGesture() {
        guard gestureIsActive else { return }
        activeStrokeID = nil
        gestureIsActive = false
        if isErasing { scheduleInkReset() }
        schedulePaletteReset()
        persist()
    }

    func cancelActiveGesture() {
        guard gestureIsActive else { return }
        if let previous = history.popLast() { strokes = previous }
        activeStrokeID = nil
        gestureIsActive = false
        persist()
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        strokes = previous
        activeStrokeID = nil
        gestureIsActive = false
        keepPaletteOpen()
        persist()
    }

    func clear() {
        guard !strokes.isEmpty else { return }
        history.append(strokes)
        if history.count > 30 { history.removeFirst() }
        strokes.removeAll()
        activeStrokeID = nil
        gestureIsActive = false
        keepPaletteOpen()
        persist()
    }

    func toggleEraser() {
        isErasing.toggle()
        eraserResetWorkItem?.cancel()
        if isErasing { scheduleInkReset() }
        keepPaletteOpen()
    }

    func selectColor(_ color: InkColor) {
        isDrawingEnabled = true
        selectedColor = color
        isErasing = false
        eraserResetWorkItem?.cancel()
        keepPaletteOpen()
    }

    func toggleDrawingMode() {
        if isDrawingEnabled {
            cancelActiveGesture()
            isDrawingEnabled = false
            isErasing = false
            eraserResetWorkItem?.cancel()
            paletteResetWorkItem?.cancel()
            isPaletteExpanded = false
        } else {
            isDrawingEnabled = true
            expandPalette()
            schedulePaletteReset()
        }
    }

    private func beginGestureIfNeeded() {
        guard !gestureIsActive else { return }
        history.append(strokes)
        if history.count > 30 { history.removeFirst() }
        gestureIsActive = true
    }

    private func scheduleInkReset() {
        eraserResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isErasing = false
        }
        eraserResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private func keepPaletteOpen() {
        expandPalette()
        schedulePaletteReset()
    }

    private func expandPalette() {
        paletteResetWorkItem?.cancel()
        isPaletteExpanded = true
    }

    private func schedulePaletteReset() {
        paletteResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isPaletteExpanded = false
        }
        paletteResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static var defaultPersistenceURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Wall", isDirectory: true)
            .appendingPathComponent("drawings.json")
    }

    private func restore() {
        guard let persistenceURL,
              let data = try? Data(contentsOf: persistenceURL),
              let saved = try? JSONDecoder().decode([InkStroke].self, from: data) else { return }
        strokes = saved
    }

    private func persist() {
        guard let persistenceURL,
              let data = try? JSONEncoder().encode(strokes) else { return }
        try? FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: persistenceURL, options: .atomic)
        onPersist?()
    }
}

struct EphemeralInkCanvas: View {
    @ObservedObject var model: InkCanvasModel

    var body: some View {
        Canvas { context, _ in
            for stroke in model.strokes {
                guard let firstPoint = stroke.points.first?.cgPoint else { continue }
                var path = Path()
                path.move(to: firstPoint)
                for point in stroke.points.dropFirst() {
                    path.addLine(to: point.cgPoint)
                }
                if stroke.points.count == 1 {
                    path.addLine(to: CGPoint(x: firstPoint.x + 0.1, y: firstPoint.y + 0.1))
                }
                context.stroke(
                    path,
                    with: .color(stroke.color.color),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { model.appendPoint($0.location) }
                .onEnded { _ in model.endGesture() }
        )
        .accessibilityHidden(true)
    }
}

struct InkControlsView: View {
    @ObservedObject var model: InkCanvasModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if model.isPaletteExpanded {
                HStack(spacing: 2) {
                    ForEach(InkColor.allCases) { color in
                        Button {
                            model.selectColor(color)
                        } label: {
                            Circle()
                                .fill(color.color)
                                .overlay(
                                    Circle()
                                        .stroke(Color.black.opacity(color == .black ? 1 : 0.28), lineWidth: 1)
                                )
                                .overlay {
                                    if color == model.selectedColor {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .frame(width: 20, height: 20)
                                .frame(width: 32, height: 40)
                        }
                        .accessibilityLabel("\(color.rawValue.capitalized) ink")
                        .accessibilityAddTraits(color == model.selectedColor ? .isSelected : [])
                    }

                    Button {
                        model.clear()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 40, height: 40)
                    }
                    .disabled(model.visibleStrokeCount == 0)
                    .opacity(model.visibleStrokeCount == 0 ? 0.22 : 1)
                    .accessibilityLabel("Clear drawing")

                    Button {
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 40, height: 40)
                    }
                    .disabled(!model.canUndo)
                    .opacity(model.canUndo ? 1 : 0.22)
                    .accessibilityLabel("Undo drawing")

                    Button {
                        model.toggleEraser()
                    } label: {
                        Image(systemName: model.isErasing ? "eraser.fill" : "eraser")
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel(model.isErasing ? "Switch to ink" : "Use eraser for ten seconds")
                }
                .font(.system(size: 17, weight: model.isErasing ? .bold : .regular))
                .foregroundColor(.black)
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.96))
                .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                .fixedSize()
                .offset(y: -62)
                .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
                .zIndex(2)
            }

            Button {
                model.toggleDrawingMode()
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 58, height: 54)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        if model.isDrawingEnabled {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.white, lineWidth: 2)
                                .padding(3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isDrawingEnabled ? "Turn off drawing" : "Turn on drawing")
            .accessibilityIdentifier("wall.pencil.button")
        }
        .frame(width: 58, height: 54, alignment: .bottomLeading)
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 1), value: model.isPaletteExpanded)
    }
}
