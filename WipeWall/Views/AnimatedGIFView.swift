import ImageIO
import CryptoKit
import SwiftUI
import UIKit

struct WallGIFItem: Identifiable, Codable, Equatable {
    enum Source: Codable, Equatable {
        case bundled(String)
        case downloaded(String)
    }

    let id: UUID
    let source: Source
    let naturalWidth: Double
    let naturalHeight: Double
    var normalizedX: Double
    var normalizedY: Double
    var scale: Double
    var rotationDegrees: Double

    var naturalSize: CGSize {
        CGSize(width: naturalWidth, height: naturalHeight)
    }

    func displayedCenter(in containerSize: CGSize) -> CGPoint {
        let displayedWidth = naturalSize.width * CGFloat(scale)
        let displayedHeight = naturalSize.height * CGFloat(scale)
        let halfWidth = min(displayedWidth / 2, containerSize.width / 2)
        let halfHeight = min(displayedHeight / 2, containerSize.height / 2)
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

    func deleteControlPosition(in containerSize: CGSize) -> CGPoint {
        let width = naturalSize.width * CGFloat(scale)
        let height = naturalSize.height * CGFloat(scale)
        let radians = CGFloat(rotationDegrees * .pi / 180)
        let corner = CGPoint(x: -width / 2, y: -height / 2)
        let rotatedCorner = CGPoint(
            x: corner.x * cos(radians) - corner.y * sin(radians),
            y: corner.x * sin(radians) + corner.y * cos(radians)
        )
        let center = displayedCenter(in: containerSize)
        return CGPoint(x: center.x + rotatedCorner.x, y: center.y + rotatedCorner.y)
    }

    func snapControlPosition(in containerSize: CGSize) -> CGPoint {
        topControlPosition(offsetFromRight: 0, in: containerSize)
    }

    func sendBackwardControlPosition(in containerSize: CGSize) -> CGPoint {
        topControlPosition(offsetFromRight: 96, in: containerSize)
    }

    func bringForwardControlPosition(in containerSize: CGSize) -> CGPoint {
        topControlPosition(offsetFromRight: 48, in: containerSize)
    }

    private func topControlPosition(offsetFromRight: CGFloat, in containerSize: CGSize) -> CGPoint {
        let width = naturalSize.width * CGFloat(scale)
        let height = naturalSize.height * CGFloat(scale)
        let radians = CGFloat(rotationDegrees * .pi / 180)
        let corner = CGPoint(x: width / 2 - offsetFromRight, y: -height / 2)
        let rotatedCorner = CGPoint(
            x: corner.x * cos(radians) - corner.y * sin(radians),
            y: corner.x * sin(radians) + corner.y * cos(radians)
        )
        let center = displayedCenter(in: containerSize)
        return CGPoint(x: center.x + rotatedCorner.x, y: center.y + rotatedCorner.y)
    }

    func containsSelectionTap(_ point: CGPoint, in containerSize: CGSize) -> Bool {
        let center = displayedCenter(in: containerSize)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radians = CGFloat(rotationDegrees * .pi / 180)
        let localX = dx * cos(radians) + dy * sin(radians)
        let localY = -dx * sin(radians) + dy * cos(radians)
        let halfWidth = naturalSize.width * CGFloat(scale) / 2
        let halfHeight = naturalSize.height * CGFloat(scale) / 2
        if abs(localX) <= halfWidth, abs(localY) <= halfHeight {
            return true
        }

        let deletePosition = deleteControlPosition(in: containerSize)
        let snapPosition = snapControlPosition(in: containerSize)
        let backwardPosition = sendBackwardControlPosition(in: containerSize)
        let forwardPosition = bringForwardControlPosition(in: containerSize)
        return hypot(point.x - deletePosition.x, point.y - deletePosition.y) <= 28
            || hypot(point.x - snapPosition.x, point.y - snapPosition.y) <= 28
            || hypot(point.x - backwardPosition.x, point.y - backwardPosition.y) <= 28
            || hypot(point.x - forwardPosition.x, point.y - forwardPosition.y) <= 28
    }
}

struct WallCloudGIFRecord: Codable, Equatable {
    let id: UUID
    let asset: String
    let naturalWidth: Double
    let naturalHeight: Double
    var normalizedX: Double
    var normalizedY: Double
    var scale: Double
    var rotationDegrees: Double
}

final class WallGIFStore: ObservableObject {
    enum Scope: Equatable {
        case wall
        case photoBooth
        case photo(String)
    }

    @Published private(set) var items: [WallGIFItem] = []
    @Published var selectedID: UUID?
    private(set) var lastControlInteraction = Date.distantPast
    @Published private(set) var importMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var addedCount = 0

    private let fileManager: FileManager
    private let rootURL: URL?
    private let metadataURL: URL?
    private let scope: Scope
    private let onPersist: (() -> Void)?

    init(
        fileManager: FileManager = .default,
        scope: Scope = .wall,
        onPersist: (() -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.scope = scope
        self.onPersist = onPersist
        let directory: String
        switch scope {
        case .wall:
            directory = "Wall/GIFs"
        case .photoBooth:
            directory = "Wall/PhotoBoothGIFs"
        case let .photo(identifier):
            directory = "Wall/PhotoEdits/\(identifier)/GIFs"
        }
        rootURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directory, isDirectory: true)
        metadataURL = rootURL?.appendingPathComponent("wall-gifs.json")
        restore()
    }

    /// Photo Booth begins as a visual copy, then persists independently. Only
    /// downloaded Wall GIFs missing from the booth seed are copied, and never
    /// linked, so moving or deleting one display cannot mutate the other.
    func seedPhotoBoothImportsIfNeeded(from wall: WallGIFStore) {
        guard scope == .photoBooth, let rootURL else { return }
        let marker = rootURL.appendingPathComponent("wall-imports-copied-v1")
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        for sourceItem in wall.items {
            guard case .downloaded = sourceItem.source,
                  let data = wall.data(for: sourceItem),
                  let size = Self.validatedGIFSize(data) else { continue }
            let filename = "\(UUID().uuidString).gif"
            do {
                try data.write(to: rootURL.appendingPathComponent(filename), options: .atomic)
                items.append(WallGIFItem(
                    id: UUID(),
                    source: .downloaded(filename),
                    naturalWidth: size.width,
                    naturalHeight: size.height,
                    normalizedX: sourceItem.normalizedX,
                    normalizedY: sourceItem.normalizedY,
                    scale: sourceItem.scale,
                    rotationDegrees: sourceItem.rotationDegrees
                ))
            } catch {
                continue
            }
        }
        persist()
        fileManager.createFile(atPath: marker.path, contents: Data())
    }

    func data(for item: WallGIFItem) -> Data? {
        switch item.source {
        case let .bundled(name):
            guard let url = Bundle.main.url(forResource: name, withExtension: "gif") else { return nil }
            return try? Data(contentsOf: url)
        case let .downloaded(filename):
            guard let rootURL else { return nil }
            return try? Data(contentsOf: rootURL.appendingPathComponent(filename))
        }
    }

    func cloudRecords() -> [(record: WallCloudGIFRecord, data: Data)] {
        items.compactMap { item in
            guard let data = data(for: item) else { return nil }
            let asset = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (
                WallCloudGIFRecord(
                    id: item.id,
                    asset: asset,
                    naturalWidth: item.naturalWidth,
                    naturalHeight: item.naturalHeight,
                    normalizedX: item.normalizedX,
                    normalizedY: item.normalizedY,
                    scale: item.scale,
                    rotationDegrees: item.rotationDegrees
                ),
                data
            )
        }
    }

    func applyCloudRecords(_ records: [WallCloudGIFRecord], assets: [String: Data]) {
        guard let rootURL else { return }
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var restored: [WallGIFItem] = []
        for record in records {
            guard record.asset.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let data = assets[record.asset],
                  Self.validatedGIFSize(data) != nil else { continue }
            let filename = "cloud-\(record.asset).gif"
            let destination = rootURL.appendingPathComponent(filename)
            if !fileManager.fileExists(atPath: destination.path) {
                try? data.write(to: destination, options: .atomic)
            }
            guard fileManager.fileExists(atPath: destination.path) else { continue }
            restored.append(WallGIFItem(
                id: record.id,
                source: .downloaded(filename),
                naturalWidth: record.naturalWidth,
                naturalHeight: record.naturalHeight,
                normalizedX: record.normalizedX,
                normalizedY: record.normalizedY,
                scale: record.scale,
                rotationDegrees: record.rotationDegrees
            ))
        }
        items = restored
        selectedID = nil
        persist()
    }

    func importGIF(from url: URL) {
        guard !isImporting, Self.isAllowedGIFURL(url) else {
            importMessage = "That image is not a GifCities GIF."
            return
        }

        isImporting = true
        importMessage = "Adding GIF…"
        var request = URLRequest(url: url)
        request.timeoutInterval = 25

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isImporting = false
                guard error == nil,
                      let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let data,
                      data.count <= 15_000_000,
                      let size = Self.validatedGIFSize(data) else {
                    self.importMessage = "Couldn’t add that GIF. Try another one."
                    return
                }
                self.saveImportedGIF(data, naturalSize: size)
            }
        }.resume()
    }

    func update(_ id: UUID, center: CGPoint, scale: CGFloat, rotation: Angle, in container: CGSize) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].normalizedX = Double(center.x / max(container.width, 1))
        items[index].normalizedY = Double(center.y / max(container.height, 1))
        items[index].scale = Double(scale)
        items[index].rotationDegrees = rotation.degrees
        persist()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        if case let .downloaded(filename) = item.source, let rootURL {
            let sourceURL = rootURL.appendingPathComponent(filename)
            let trashURL = rootURL.appendingPathComponent("Trash", isDirectory: true)
            try? fileManager.createDirectory(at: trashURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: sourceURL.path) {
                try? fileManager.moveItem(
                    at: sourceURL,
                    to: trashURL.appendingPathComponent("\(UUID().uuidString)-\(filename)")
                )
            }
        }
        items.remove(at: index)
        if selectedID == id { selectedID = nil }
        persist()
    }

    func snapRotation(_ id: UUID) {
        lastControlInteraction = Date()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].rotationDegrees = WallRotationSnap.closest(to: items[index].rotationDegrees)
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

    func clearImportMessage() {
        importMessage = nil
    }

    func dismissSelectionIfTappedOutside(_ point: CGPoint, in containerSize: CGSize) {
        guard let selectedID,
              let item = items.first(where: { $0.id == selectedID }),
              !item.containsSelectionTap(point, in: containerSize) else { return }
        self.selectedID = nil
    }

    @discardableResult
    func selectTopmost(at point: CGPoint, in containerSize: CGSize) -> Bool {
        guard let item = items.reversed().first(where: { $0.containsSelectionTap(point, in: containerSize) }) else {
            return false
        }
        selectedID = item.id
        return true
    }

    func contains(_ id: UUID, point: CGPoint, in containerSize: CGSize) -> Bool {
        items.first(where: { $0.id == id })?.containsSelectionTap(point, in: containerSize) == true
    }

    private func restore() {
        guard let metadataURL,
              let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([WallGIFItem].self, from: data) else {
            items = Self.seedItems(for: scope)
            if scope == .wall { migrateLegacyPositions() }
            persist()
            return
        }
        items = decoded
    }

    private func migrateLegacyPositions() {
        let defaults = UserDefaults.standard
        let legacyKeys = ["wall.gif.1", "wall.gif.2"]
        for (index, key) in legacyKeys.enumerated() where items.indices.contains(index) {
            let x = defaults.double(forKey: "\(key).x")
            let y = defaults.double(forKey: "\(key).y")
            if x >= 0, x <= 1, y >= 0, y <= 1, defaults.object(forKey: "\(key).x") != nil {
                items[index].normalizedX = x
                items[index].normalizedY = y
            }
        }
    }

    private func saveImportedGIF(_ data: Data, naturalSize: CGSize) {
        guard let rootURL else {
            importMessage = "Wall couldn’t open its GIF folder."
            return
        }

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let filename = "\(UUID().uuidString).gif"
            try data.write(to: rootURL.appendingPathComponent(filename), options: .atomic)

            let maximumDisplayEdge: CGFloat = 260
            let largestNaturalEdge = max(naturalSize.width, naturalSize.height, 1)
            let initialScale = min(1, maximumDisplayEdge / largestNaturalEdge)
            let item = WallGIFItem(
                id: UUID(),
                source: .downloaded(filename),
                naturalWidth: naturalSize.width,
                naturalHeight: naturalSize.height,
                normalizedX: 0.5,
                normalizedY: 0.5,
                scale: Double(initialScale),
                rotationDegrees: 0
            )
            items.append(item)
            importMessage = scope == .wall ? "Added to Wall." : "GIF added."
            addedCount += 1
            persist()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            importMessage = "Wall couldn’t save that GIF."
        }
    }

    private func persist() {
        guard let metadataURL, let rootURL,
              let data = try? JSONEncoder().encode(items) else { return }
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? data.write(to: metadataURL, options: .atomic)
        onPersist?()
    }

    private func move(_ id: UUID, toFront: Bool) {
        guard let currentIndex = items.firstIndex(where: { $0.id == id }) else { return }
        let destination = toFront ? items.count - 1 : 0
        guard destination != currentIndex else { return }
        let item = items.remove(at: currentIndex)
        items.insert(item, at: toFront ? items.endIndex : items.startIndex)
        persist()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private static func isAllowedGIFURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "blob.gifcities.org"
            && url.path.lowercased().hasSuffix(".gif")
    }

    private static func validatedGIFSize(_ data: Data) -> CGSize? {
        guard data.count >= 6,
              let signature = String(data: data.prefix(6), encoding: .ascii),
              signature == "GIF87a" || signature == "GIF89a",
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetCount(source) <= 500,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func seedItems(for scope: Scope) -> [WallGIFItem] {
        let wallItems = [
            WallGIFItem(
                id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
                source: .bundled("wall-gif-1"),
                naturalWidth: 177,
                naturalHeight: 191,
                normalizedX: 0.293,
                normalizedY: 0.852,
                scale: 1,
                rotationDegrees: 0
            ),
            WallGIFItem(
                id: UUID(uuidString: "70000000-0000-0000-0000-000000000002")!,
                source: .bundled("wall-gif-2"),
                naturalWidth: 400,
                naturalHeight: 50,
                normalizedX: 0.598,
                normalizedY: 0.944,
                scale: 1,
                rotationDegrees: 0
            )
        ]
        switch scope {
        case .wall:
            return wallItems
        case .photo:
            return []
        case .photoBooth:
            return wallItems + [
            WallGIFItem(
                id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
                source: .bundled("photo-booth-1"),
                naturalWidth: 102,
                naturalHeight: 96,
                normalizedX: 0.23,
                normalizedY: 0.28,
                scale: 1.2,
                rotationDegrees: -8
            ),
            WallGIFItem(
                id: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!,
                source: .bundled("photo-booth-2"),
                naturalWidth: 144,
                naturalHeight: 144,
                normalizedX: 0.77,
                normalizedY: 0.28,
                scale: 1.05,
                rotationDegrees: 7
            ),
            WallGIFItem(
                id: UUID(uuidString: "71000000-0000-0000-0000-000000000003")!,
                source: .bundled("photo-booth-3"),
                naturalWidth: 129,
                naturalHeight: 124,
                normalizedX: 0.22,
                normalizedY: 0.71,
                scale: 1.1,
                rotationDegrees: 5
            ),
            WallGIFItem(
                id: UUID(uuidString: "71000000-0000-0000-0000-000000000004")!,
                source: .bundled("photo-booth-4"),
                naturalWidth: 97,
                naturalHeight: 84,
                normalizedX: 0.78,
                normalizedY: 0.70,
                scale: 1.25,
                rotationDegrees: -6
            )
            ]
        }
    }
}

private final class AnimatedGIFCache {
    static let shared = NSCache<NSString, UIImage>()
}

struct WallAnimatedGIFView: UIViewRepresentable {
    let cacheKey: String
    let data: Data

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.backgroundColor = .clear
        view.contentMode = .scaleAspectFit
        view.layer.magnificationFilter = .nearest
        view.isAccessibilityElement = false
        view.image = Self.animatedImage(data: data, cacheKey: cacheKey)
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if !uiView.isAnimating { uiView.startAnimating() }
    }

    private static func animatedImage(data: Data, cacheKey: String) -> UIImage? {
        let key = cacheKey as NSString
        if let cached = AnimatedGIFCache.shared.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            duration += max(0.02, delay)
            frames.append(UIImage(cgImage: image, scale: 1, orientation: .up))
        }

        guard !frames.isEmpty,
              let animated = UIImage.animatedImage(with: frames, duration: max(duration, 0.1)) else { return nil }
        AnimatedGIFCache.shared.setObject(animated, forKey: key, cost: data.count)
        return animated
    }
}

struct WallGIFDecorations: View {
    @ObservedObject var store: WallGIFStore
    @ObservedObject var layers: WallLayerStore
    let containerSize: CGSize
    @ObservedObject var ink: InkCanvasModel
    @Binding var isManipulatingDecoration: Bool
    @Binding var isEditing: Bool
    let onRequestEdit: (UUID) -> Void

    var body: some View {
        ForEach(store.items) { item in
            if let data = store.data(for: item) {
                EditableGIFDecoration(
                    item: item,
                    data: data,
                    containerSize: containerSize,
                    store: store,
                    layers: layers,
                    ink: ink,
                    isManipulatingAnyDecoration: $isManipulatingDecoration,
                    isEditing: $isEditing,
                    onRequestEdit: { onRequestEdit(item.id) }
                )
            }

            if isEditing && store.selectedID == item.id {
                GIFEditControlBar(
                    item: item,
                    containerSize: containerSize,
                    store: store,
                    layers: layers,
                )
                .zIndex(70_000)
            }
        }
    }
}

struct EditableGIFDecoration: View {
    let item: WallGIFItem
    let data: Data
    let containerSize: CGSize
    @ObservedObject var store: WallGIFStore
    @ObservedObject var layers: WallLayerStore
    @ObservedObject var ink: InkCanvasModel
    @Binding var isManipulatingAnyDecoration: Bool
    @Binding var isEditing: Bool
    let onRequestEdit: () -> Void

    @State private var liveCenter: CGPoint?
    @State private var liveScale: CGFloat?
    @State private var liveRotation: Angle?
    @State private var dragOrigin: CGPoint?
    @State private var scaleOrigin: CGFloat?
    @State private var rotationOrigin: Angle?
    @State private var suppressDrawing = false

    private var isSelected: Bool { store.selectedID == item.id }

    var body: some View {
        decorationContent
            .simultaneousGesture(
                drawingGesture,
                including: WallInputPolicy.routesDrawingGesture(
                    isEditing: isEditing,
                    isDrawingEnabled: ink.isDrawingEnabled,
                    allowsDrawingThrough: true
                ) ? .gesture : .none
            )
            .wallObjectEditLongPress(enabled: !isEditing, action: onRequestEdit)
            .accessibilityHint(
                isEditing && isSelected
                    ? "Drag, pinch, or rotate. Delete is at the top left."
                    : "Long-press to edit this GIF"
            )
    }

    private var decorationContent: some View {
        ZStack(alignment: .topLeading) {
            WallAnimatedGIFView(cacheKey: item.id.uuidString, data: data)
                .frame(width: item.naturalSize.width, height: item.naturalSize.height)

            if isEditing && isSelected {
                Rectangle()
                    .stroke(Color.black, lineWidth: 1 / max(displayScale, 0.25))
                    .allowsHitTesting(false)
            }

            if isEditing && isSelected {
                WallTransformGestureSurface(
                    accessibilityLabel: "Animated GIF",
                    accessibilityIdentifier: "wall.gif.\(item.id.uuidString)",
                    accessibilityValue: transformAccessibilityValue,
                    onTap: select,
                    onPan: handlePan,
                    onPinch: handlePinch,
                    onRotation: handleRotation
                )
            } else if isEditing {
                WallObjectSelectionSurface(
                    accessibilityLabel: "Select animated GIF",
                    accessibilityIdentifier: "wall.gif.\(item.id.uuidString).select",
                    action: select
                )
            }
        }
        .frame(width: item.naturalSize.width, height: item.naturalSize.height)
        .contentShape(Rectangle())
        .scaleEffect(displayScale)
        .rotationEffect(displayRotation)
        .position(displayCenter)
        .zIndex(layers.zIndex(for: .gif(item.id)))
        .shadow(color: isEditing && isSelected ? Color.black.opacity(0.12) : .clear, radius: 8)
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.9), value: isSelected)
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(isEditing ? "" : "Animated GIF")
        .onChange(of: containerSize) { _ in
            liveCenter = nil
            dragOrigin = nil
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
    }

    private var displayScale: CGFloat {
        liveScale ?? CGFloat(item.scale)
    }

    private var displayRotation: Angle {
        liveRotation ?? .degrees(item.rotationDegrees)
    }

    private var displayCenter: CGPoint {
        if let liveCenter { return liveCenter }
        let saved = CGPoint(
            x: item.normalizedX * containerSize.width,
            y: item.normalizedY * containerSize.height
        )
        return clamp(saved, scale: displayScale)
    }

    private var transformAccessibilityValue: String {
        "x:\(Int(displayCenter.x.rounded())),y:\(Int(displayCenter.y.rounded())),scale:\(String(format: "%.3f", displayScale)),rotation:\(String(format: "%.3f", displayRotation.degrees))"
    }

    private var drawingGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("wall-canvas"))
            .onChanged { value in
                guard !isEditing, !suppressDrawing else { return }
                ink.appendPoint(value.location)
            }
            .onEnded { _ in
                if isEditing || suppressDrawing {
                    ink.cancelActiveGesture()
                } else {
                    ink.endGesture()
                }
            }
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

    private var scaleGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard isEditing, isSelected else { return }
                beginDirectManipulationIfNeeded()
                if scaleOrigin == nil { scaleOrigin = displayScale }
                liveScale = min(max((scaleOrigin ?? 1) * value, 0.18), 5)
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

    private func beginSelectionIfNeeded() {
        guard dragOrigin == nil else { return }
        suppressDrawing = true
        ink.cancelActiveGesture()
        store.selectedID = item.id
        dragOrigin = displayCenter
        liveCenter = displayCenter
        isManipulatingAnyDecoration = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func beginDirectManipulationIfNeeded() {
        suppressDrawing = true
        ink.cancelActiveGesture()
        if store.selectedID != item.id {
            store.selectedID = item.id
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        isManipulatingAnyDecoration = true
    }

    private func select() {
        guard isEditing else { return }
        if store.selectedID != item.id {
            store.selectedID = item.id
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
            liveScale = min(max((scaleOrigin ?? 1) * value, 0.18), 5)
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
            item.id,
            center: clamp(displayCenter, scale: displayScale),
            scale: displayScale,
            rotation: displayRotation,
            in: containerSize
        )
    }

    private func endInteractionFlag() {
        isManipulatingAnyDecoration = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            suppressDrawing = false
        }
    }

    private func clamp(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        let displayed = CGSize(
            width: item.naturalSize.width * scale,
            height: item.naturalSize.height * scale
        )
        let halfWidth = min(displayed.width / 2, containerSize.width / 2)
        let halfHeight = min(displayed.height / 2, containerSize.height / 2)
        return CGPoint(
            x: min(max(point.x, halfWidth), max(halfWidth, containerSize.width - halfWidth)),
            y: min(max(point.y, halfHeight), max(halfHeight, containerSize.height - halfHeight))
        )
    }
}

struct GIFEditControlBar: View {
    let item: WallGIFItem
    let containerSize: CGSize
    @ObservedObject var store: WallGIFStore
    @ObservedObject var layers: WallLayerStore

    var body: some View {
        HStack(spacing: 2) {
            depthControl(
                .back,
                label: "Send GIF all the way to back",
                identifier: "wall.gif.\(item.id.uuidString).back"
            ) {
                layers.sendToBack(.gif(item.id))
            }
            depthControl(
                .front,
                label: "Bring GIF all the way to front",
                identifier: "wall.gif.\(item.id.uuidString).forward"
            ) {
                layers.bringToFront(.gif(item.id))
            }
            control(
                symbol: "rotate.right",
                label: "Snap GIF rotation",
                identifier: "wall.gif.\(item.id.uuidString).snap"
            ) {
                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.82)) {
                    store.snapRotation(item.id)
                }
            }
            control(
                symbol: "xmark",
                label: "Delete GIF",
                identifier: "wall.gif.\(item.id.uuidString).delete"
            ) {
                store.delete(item.id)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        Button {
            layers.noteControlInteraction()
            action()
        } label: {
            WallLayerDepthIcon(placement: placement)
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

    private func control(
        symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            layers.noteControlInteraction()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
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
        let center = item.displayedCenter(in: containerSize)
        let width = item.naturalSize.width * CGFloat(item.scale)
        let height = item.naturalSize.height * CGFloat(item.scale)
        let radians = CGFloat(item.rotationDegrees * .pi / 180)
        let boundingHalfHeight = abs(width * sin(radians)) / 2 + abs(height * cos(radians)) / 2
        return CGPoint(
            x: min(max(center.x, 92), max(92, containerSize.width - 92)),
            y: max(25, center.y - boundingHalfHeight - 25)
        )
    }
}
