import SwiftUI

enum WallElementID: String, CaseIterable, Codable {
    case clock
    case weather
    case transit
    case note
    case goonCounter
    case sonosNowPlaying
    case mediaControls
    case toolControls
}

struct WallElementTransform: Codable, Equatable {
    var normalizedX: Double
    var normalizedY: Double
    var scale: Double
    var rotationDegrees: Double
}

private struct WallElementGeometry {
    let baseSize: CGSize
    let defaultCenter: CGPoint
    let containerSize: CGSize
}

enum WallRotationSnap {
    static let angles = [0.0, 45.0, 90.0, 135.0, 180.0]

    static func closest(to degrees: Double) -> Double {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return angles.min { circularDistance(normalized, $0) < circularDistance(normalized, $1) } ?? 0
    }

    private static func circularDistance(_ first: Double, _ second: Double) -> Double {
        let distance = abs(first - second)
        return min(distance, 360 - distance)
    }
}

/// Centralizes the interaction boundary between the wall's controls and its
/// optional ink layer. A zero-distance drawing gesture must not exist while
/// the pencil is off: even a no-op recognizer can win against a Button tap.
enum WallInputPolicy {
    static func routesDrawingGesture(
        isEditing: Bool,
        isDrawingEnabled: Bool,
        allowsDrawingThrough: Bool
    ) -> Bool {
        !isEditing && isDrawingEnabled && allowsDrawingThrough
    }
}

final class WallElementStore: ObservableObject {
    @Published private(set) var transforms: [WallElementID: WallElementTransform] = [:]
    @Published private(set) var stackingOrder: [WallElementID]
    @Published var selectedID: WallElementID?
    private(set) var lastControlInteraction = Date.distantPast

    private let defaults: UserDefaults
    private let persistenceKey: String
    private var geometry: [WallElementID: WallElementGeometry] = [:]

    init(defaults: UserDefaults = .standard, persistenceKey: String = "wall.element.transforms.v1") {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        if ProcessInfo.processInfo.arguments.contains("-ResetWallTestState") {
            defaults.removeObject(forKey: persistenceKey)
            defaults.removeObject(forKey: "\(persistenceKey).stacking")
        }
        let savedOrder = defaults.stringArray(forKey: "\(persistenceKey).stacking")?
            .compactMap(WallElementID.init(rawValue:)) ?? []
        stackingOrder = savedOrder + WallElementID.allCases.filter { !savedOrder.contains($0) }
        if let data = defaults.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode([WallElementID: WallElementTransform].self, from: data) {
            transforms = decoded
        }
    }

    func cloudSnapshotData() -> Data? {
        try? JSONEncoder().encode(transforms)
    }

    func applyCloudSnapshotData(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([WallElementID: WallElementTransform].self, from: data) else { return }
        transforms = decoded
        selectedID = nil
        persist()
    }

    func register(_ id: WallElementID, baseSize: CGSize, defaultCenter: CGPoint, containerSize: CGSize) {
        geometry[id] = WallElementGeometry(
            baseSize: baseSize,
            defaultCenter: defaultCenter,
            containerSize: containerSize
        )
    }

    func transform(for id: WallElementID, defaultCenter: CGPoint, in containerSize: CGSize) -> WallElementTransform {
        transforms[id] ?? WallElementTransform(
            normalizedX: Double(defaultCenter.x / max(containerSize.width, 1)),
            normalizedY: Double(defaultCenter.y / max(containerSize.height, 1)),
            scale: 1,
            rotationDegrees: 0
        )
    }

    func update(_ id: WallElementID, center: CGPoint, scale: CGFloat, rotation: Angle, in containerSize: CGSize) {
        transforms[id] = WallElementTransform(
            normalizedX: Double(center.x / max(containerSize.width, 1)),
            normalizedY: Double(center.y / max(containerSize.height, 1)),
            scale: Double(scale),
            rotationDegrees: rotation.degrees
        )
        persist()
    }

    func snapRotation(_ id: WallElementID, defaultCenter: CGPoint, in containerSize: CGSize) {
        lastControlInteraction = Date()
        var value = transform(for: id, defaultCenter: defaultCenter, in: containerSize)
        value.rotationDegrees = WallRotationSnap.closest(to: value.rotationDegrees)
        transforms[id] = value
        persist()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func sendToBack(_ id: WallElementID) {
        lastControlInteraction = Date()
        move(id, toFront: false)
    }

    func bringToFront(_ id: WallElementID) {
        lastControlInteraction = Date()
        move(id, toFront: true)
    }

    func zIndex(for id: WallElementID) -> Double {
        Double(stackingOrder.firstIndex(of: id) ?? 0)
    }

    func dismissSelectionIfTappedOutside(_ point: CGPoint) {
        guard let selectedID, !selectionContains(selectedID, point: point) else { return }
        self.selectedID = nil
    }

    @discardableResult
    func selectTopmost(at point: CGPoint) -> Bool {
        guard let id = stackingOrder.reversed().first(where: { selectionContains($0, point: point) }) else {
            return false
        }
        selectedID = id
        return true
    }

    func contains(_ id: WallElementID, point: CGPoint) -> Bool {
        selectionContains(id, point: point)
    }

    private func selectionContains(_ id: WallElementID, point: CGPoint) -> Bool {
        guard let geometry = geometry[id] else { return false }
        let transform = transform(
            for: id,
            defaultCenter: geometry.defaultCenter,
            in: geometry.containerSize
        )
        let center = CGPoint(
            x: transform.normalizedX * geometry.containerSize.width,
            y: transform.normalizedY * geometry.containerSize.height
        )
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radians = CGFloat(transform.rotationDegrees * .pi / 180)
        let localX = dx * cos(radians) + dy * sin(radians)
        let localY = -dx * sin(radians) + dy * cos(radians)
        let halfWidth = geometry.baseSize.width * CGFloat(transform.scale) / 2
        let halfHeight = geometry.baseSize.height * CGFloat(transform.scale) / 2
        return abs(localX) <= halfWidth && abs(localY) <= halfHeight
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(transforms) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private func move(_ id: WallElementID, toFront: Bool) {
        guard let currentIndex = stackingOrder.firstIndex(of: id) else { return }
        let destination = toFront ? stackingOrder.count - 1 : 0
        guard destination != currentIndex else { return }
        stackingOrder.remove(at: currentIndex)
        stackingOrder.insert(id, at: toFront ? stackingOrder.endIndex : stackingOrder.startIndex)
        defaults.set(stackingOrder.map(\.rawValue), forKey: "\(persistenceKey).stacking")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

struct MovableWallElement<Content: View>: View {
    let id: WallElementID
    let baseSize: CGSize
    let defaultCenter: CGPoint
    let containerSize: CGSize
    let allowsDrawingThrough: Bool
    var allowsSelectedContentInteraction = false
    var selectedContentInteractionExclusionTrailing: CGFloat = 0
    @ObservedObject var store: WallElementStore
    @ObservedObject var layers: WallLayerStore
    @ObservedObject var ink: InkCanvasModel
    @Binding var isManipulatingAnyElement: Bool
    @Binding var isEditing: Bool
    let onRequestEdit: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var liveCenter: CGPoint?
    @State private var liveScale: CGFloat?
    @State private var liveRotation: Angle?
    @State private var dragOrigin: CGPoint?
    @State private var scaleOrigin: CGFloat?
    @State private var rotationOrigin: Angle?
    @State private var suppressDrawing = false

    private var isSelected: Bool { store.selectedID == id }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isEditing && isSelected && allowsSelectedContentInteraction {
                editInteractionSurface
                    .frame(
                        width: max(baseSize.width - selectedContentInteractionExclusionTrailing, 1),
                        height: baseSize.height
                    )
                    .frame(width: baseSize.width, height: baseSize.height, alignment: .leading)
            }

            content()
                .frame(width: baseSize.width, height: baseSize.height)
                .allowsHitTesting(!isEditing || (isSelected && allowsSelectedContentInteraction))
                // UIViewRepresentable gesture surfaces can otherwise outrank
                // sibling SwiftUI buttons on older iPadOS releases even when
                // declared first in the ZStack. Keep selected content controls
                // explicitly above the transform recognizers.
                .zIndex(isEditing && isSelected && allowsSelectedContentInteraction ? 2 : 0)

            if isEditing && isSelected && !allowsSelectedContentInteraction {
                editInteractionSurface
            } else if isEditing && !isSelected {
                WallObjectSelectionSurface(
                    accessibilityLabel: "Select \(id.rawValue.capitalized) wall element",
                    accessibilityIdentifier: "wall.element.\(id.rawValue).select",
                    action: select
                )
            }

            if routesDrawingGesture {
                drawingInteractionSurface
            }

            if isEditing && isSelected {
                Rectangle()
                    .stroke(Color.black, lineWidth: 1 / max(displayScale, 0.25))
                    .allowsHitTesting(false)

                Text(transformAccessibilityValue)
                    .font(.system(size: 1))
                    .opacity(0.001)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("wall.element.\(id.rawValue).transform")

            }
        }
        .frame(width: baseSize.width, height: baseSize.height)
        .contentShape(Rectangle())
        .scaleEffect(displayScale)
        .rotationEffect(displayRotation)
        .position(displayCenter)
        .zIndex(layers.zIndex(for: .element(id)))
        .shadow(color: isEditing && isSelected ? Color.black.opacity(0.12) : .clear, radius: 8)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 1), value: isSelected)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: savedTransform.rotationDegrees)
        .wallObjectEditLongPress(enabled: !isEditing, action: onRequestEdit)
        .onAppear(perform: registerGeometry)
        .onChange(of: containerSize) { _ in
            liveCenter = nil
            dragOrigin = nil
            registerGeometry()
        }
        .onChange(of: baseSize) { _ in
            registerGeometry()
        }
        .onChange(of: isEditing) { editing in
            guard !editing else { return }
            liveCenter = nil
            liveScale = nil
            liveRotation = nil
            dragOrigin = nil
            scaleOrigin = nil
            rotationOrigin = nil
            suppressDrawing = false
        }
        .accessibilityHint(isEditing ? "Drag to move; pinch or rotate to transform." : "Long-press to edit this item")
    }

    private var savedTransform: WallElementTransform {
        store.transform(for: id, defaultCenter: defaultCenter, in: containerSize)
    }

    private var displayScale: CGFloat { liveScale ?? CGFloat(savedTransform.scale) }
    private var displayRotation: Angle { liveRotation ?? .degrees(savedTransform.rotationDegrees) }

    private var routesDrawingGesture: Bool {
        WallInputPolicy.routesDrawingGesture(
            isEditing: isEditing,
            isDrawingEnabled: ink.isDrawingEnabled,
            allowsDrawingThrough: allowsDrawingThrough
        )
    }

    private var drawingInteractionSurface: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .gesture(drawingGesture)
    }

    private var editInteractionSurface: some View {
        WallTransformGestureSurface(
            accessibilityLabel: "\(id.rawValue.capitalized) wall element",
            accessibilityIdentifier: "wall.element.\(id.rawValue)",
            accessibilityValue: transformAccessibilityValue,
            onTap: select,
            onPan: handlePan,
            onPinch: handlePinch,
            onRotation: handleRotation
        )
    }

    private var transformAccessibilityValue: String {
        "x:\(Int(displayCenter.x.rounded())),y:\(Int(displayCenter.y.rounded())),scale:\(String(format: "%.3f", displayScale)),rotation:\(String(format: "%.3f", displayRotation.degrees))"
    }

    private var displayCenter: CGPoint {
        if let liveCenter { return liveCenter }
        return clamp(
            CGPoint(
                x: savedTransform.normalizedX * containerSize.width,
                y: savedTransform.normalizedY * containerSize.height
            ),
            scale: displayScale
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("wall-canvas"))
            .onChanged { value in
                guard isEditing else { return }
                beginSelectionIfNeeded()
                updateCenter(translation: value.translation)
            }
            .onEnded { _ in
                guard isEditing else { return }
                finishManipulation()
            }
    }

    private var selectionGesture: some Gesture {
        TapGesture()
            .onEnded {
                guard isEditing else { return }
                if store.selectedID != id {
                    store.selectedID = id
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }

    private var scaleGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isEditing, isSelected else { return }
                beginDirectManipulationIfNeeded()
                if scaleOrigin == nil { scaleOrigin = displayScale }
                liveScale = min(max((scaleOrigin ?? 1) * value, 0.35), 3)
                liveCenter = clamp(displayCenter, scale: displayScale)
            }
            .onEnded { _ in
                guard isEditing, isSelected else { return }
                scaleOrigin = nil
                commitTransform()
                endInteractionFlag()
            }
    }

    private var rotationGesture: some Gesture {
        RotationGesture()
            .onChanged { value in
                guard isEditing, isSelected else { return }
                beginDirectManipulationIfNeeded()
                if rotationOrigin == nil { rotationOrigin = displayRotation }
                liveRotation = (rotationOrigin ?? .zero) + value
            }
            .onEnded { _ in
                guard isEditing, isSelected else { return }
                rotationOrigin = nil
                commitTransform()
                endInteractionFlag()
            }
    }

    private var drawingGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("wall-canvas"))
            .onChanged { value in
                guard !isEditing, allowsDrawingThrough, !suppressDrawing else { return }
                ink.appendPoint(value.location)
            }
            .onEnded { _ in
                guard allowsDrawingThrough else { return }
                if isEditing || suppressDrawing {
                    ink.cancelActiveGesture()
                } else {
                    ink.endGesture()
                }
            }
    }

    private func beginSelectionIfNeeded() {
        guard dragOrigin == nil else { return }
        suppressDrawing = true
        ink.cancelActiveGesture()
        store.selectedID = id
        dragOrigin = displayCenter
        liveCenter = displayCenter
        isManipulatingAnyElement = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func beginDirectManipulationIfNeeded() {
        suppressDrawing = true
        ink.cancelActiveGesture()
        if store.selectedID != id {
            store.selectedID = id
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        isManipulatingAnyElement = true
    }

    private func select() {
        guard isEditing else { return }
        if store.selectedID != id {
            store.selectedID = id
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func handlePan(_ phase: WallTransformGesturePhase, _ translation: CGSize) {
        guard isEditing else { return }
        switch phase {
        case .began:
            beginSelectionIfNeeded()
        case .changed:
            beginSelectionIfNeeded()
            updateCenter(translation: translation)
        case .ended:
            updateCenter(translation: translation)
            finishManipulation()
        case .cancelled:
            liveCenter = nil
            dragOrigin = nil
            endInteractionFlag()
        }
    }

    private func handlePinch(_ phase: WallTransformGesturePhase, _ value: CGFloat) {
        guard isEditing else { return }
        switch phase {
        case .began:
            beginDirectManipulationIfNeeded()
            scaleOrigin = displayScale
        case .changed:
            beginDirectManipulationIfNeeded()
            if scaleOrigin == nil { scaleOrigin = displayScale }
            liveScale = min(max((scaleOrigin ?? 1) * value, 0.35), 3)
            liveCenter = clamp(displayCenter, scale: displayScale)
        case .ended:
            commitTransform()
            scaleOrigin = nil
            liveScale = nil
            liveCenter = nil
            endInteractionFlag()
        case .cancelled:
            scaleOrigin = nil
            liveScale = nil
            liveCenter = nil
            endInteractionFlag()
        }
    }

    private func handleRotation(_ phase: WallTransformGesturePhase, _ value: Angle) {
        guard isEditing else { return }
        switch phase {
        case .began:
            beginDirectManipulationIfNeeded()
            rotationOrigin = displayRotation
        case .changed:
            beginDirectManipulationIfNeeded()
            if rotationOrigin == nil { rotationOrigin = displayRotation }
            liveRotation = (rotationOrigin ?? .zero) + value
        case .ended:
            commitTransform()
            rotationOrigin = nil
            liveRotation = nil
            endInteractionFlag()
        case .cancelled:
            rotationOrigin = nil
            liveRotation = nil
            endInteractionFlag()
        }
    }

    private func updateCenter(translation: CGSize) {
        guard let origin = dragOrigin else { return }
        liveCenter = clamp(
            CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
            scale: displayScale
        )
    }

    private func finishManipulation() {
        guard suppressDrawing else { return }
        commitTransform()
        dragOrigin = nil
        endInteractionFlag()
    }

    private func commitTransform() {
        store.update(
            id,
            center: clamp(displayCenter, scale: displayScale),
            scale: displayScale,
            rotation: displayRotation,
            in: containerSize
        )
    }

    private func endInteractionFlag() {
        isManipulatingAnyElement = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { suppressDrawing = false }
    }

    private func registerGeometry() {
        store.register(id, baseSize: baseSize, defaultCenter: defaultCenter, containerSize: containerSize)
    }

    private func clamp(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        let halfWidth = min(baseSize.width * scale / 2, containerSize.width / 2)
        let halfHeight = min(baseSize.height * scale / 2, containerSize.height / 2)
        return CGPoint(
            x: min(max(point.x, halfWidth), max(halfWidth, containerSize.width - halfWidth)),
            y: min(max(point.y, halfHeight), max(halfHeight, containerSize.height - halfHeight))
        )
    }
}

/// Drawn outside the transformed object so sending an element to the absolute
/// back never buries the controls needed to bring it forward again.
struct WallElementEditControls: View {
    let id: WallElementID
    let baseSize: CGSize
    let defaultCenter: CGPoint
    let containerSize: CGSize
    @ObservedObject var store: WallElementStore
    @ObservedObject var layers: WallLayerStore

    var body: some View {
        HStack(spacing: 2) {
            depthControl(.back, label: "Send all the way to back", identifier: "wall.element.\(id.rawValue).back") {
                layers.sendToBack(.element(id))
            }
            depthControl(.front, label: "Bring all the way to front", identifier: "wall.element.\(id.rawValue).forward") {
                layers.bringToFront(.element(id))
            }
            symbolControl("rotate.right", label: "Snap rotation", identifier: "wall.element.\(id.rawValue).snap") {
                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.82)) {
                    store.snapRotation(id, defaultCenter: defaultCenter, in: containerSize)
                }
            }
        }
        .padding(3)
        .background(Color.white)
        .overlay(Capsule().stroke(Color.black, lineWidth: 1))
        .clipShape(Capsule())
        .position(controlBarPosition)
    }

    private func depthControl(
        _ placement: WallLayerDepthPlacement,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        control(label: label, identifier: identifier, action: action) {
            WallLayerDepthIcon(placement: placement)
        }
    }

    private func symbolControl(
        _ symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        control(label: label, identifier: identifier, action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
        }
    }

    private func control<Icon: View>(
        label: String,
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button {
            layers.noteControlInteraction()
            action()
        } label: {
            icon()
                .foregroundColor(.white)
                .frame(width: 29, height: 29)
                .background(Color.black)
                .clipShape(Circle())
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var controlBarPosition: CGPoint {
        let transform = store.transform(for: id, defaultCenter: defaultCenter, in: containerSize)
        let center = CGPoint(
            x: CGFloat(transform.normalizedX) * containerSize.width,
            y: CGFloat(transform.normalizedY) * containerSize.height
        )
        let width = baseSize.width * CGFloat(transform.scale)
        let height = baseSize.height * CGFloat(transform.scale)
        let radians = CGFloat(transform.rotationDegrees * .pi / 180)
        let boundingHalfHeight = abs(width * sin(radians)) / 2 + abs(height * cos(radians)) / 2
        return CGPoint(
            x: min(max(center.x, 76), max(76, containerSize.width - 76)),
            y: max(25, center.y - boundingHalfHeight - 25)
        )
    }
}
