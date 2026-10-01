import SwiftUI

enum WallLayerID: Hashable {
    case element(WallElementID)
    case gif(UUID)
    case widget(UUID)

    var storageKey: String {
        switch self {
        case let .element(id): return "element:\(id.rawValue)"
        case let .gif(id): return "gif:\(id.uuidString.lowercased())"
        case let .widget(id): return "widget:\(id.uuidString.lowercased())"
        }
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "element":
            guard let id = WallElementID(rawValue: parts[1]) else { return nil }
            self = .element(id)
        case "gif":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .gif(id)
        case "widget":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .widget(id)
        default:
            return nil
        }
    }
}

final class WallLayerStore: ObservableObject {
    @Published private(set) var order: [WallLayerID]
    private(set) var lastControlInteraction = Date.distantPast

    private let defaults: UserDefaults
    private let persistenceKey: String

    init(defaults: UserDefaults = .standard, persistenceKey: String = "wall.global-layers.v1") {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        order = defaults.stringArray(forKey: persistenceKey)?
            .compactMap(WallLayerID.init(storageKey:)) ?? []
    }

    func cloudStorageKeys() -> [String] {
        order.map(\.storageKey)
    }

    func applyCloudStorageKeys(_ keys: [String]) {
        order = keys.compactMap(WallLayerID.init(storageKey:))
        persist()
    }

    func synchronize(with available: [WallLayerID]) {
        let availableSet = Set(available)
        let retained = order.filter { availableSet.contains($0) }
        let next = retained + available.filter { !retained.contains($0) }
        guard next != order else { return }
        order = next
        persist()
    }

    /// `order` is always stored back-to-front. Layer actions are deliberately
    /// absolute so one press has one predictable result across every object
    /// family (elements, GIFs, and widgets).
    func sendToBack(_ id: WallLayerID) { move(id, toFront: false) }
    func bringToFront(_ id: WallLayerID) { move(id, toFront: true) }

    func noteControlInteraction() {
        lastControlInteraction = Date()
    }

    func zIndex(for id: WallLayerID) -> Double {
        100 + Double(order.firstIndex(of: id) ?? 0)
    }

    private func move(_ id: WallLayerID, toFront: Bool) {
        lastControlInteraction = Date()
        guard let current = order.firstIndex(of: id), !order.isEmpty else { return }
        let destination = toFront ? order.count - 1 : 0
        guard destination != current else {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            return
        }
        order.remove(at: current)
        order.insert(id, at: toFront ? order.endIndex : order.startIndex)
        persist()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func persist() {
        defaults.set(order.map(\.storageKey), forKey: persistenceKey)
    }
}

enum WallLayerDepthPlacement {
    case back
    case front
}

/// Two overlapping sheets: the solid sheet is literally rendered behind or
/// in front of the dashed reference sheet, matching the action it performs.
struct WallLayerDepthIcon: View {
    let placement: WallLayerDepthPlacement

    var body: some View {
        ZStack {
            if placement == .front {
                dashedSquare.offset(x: -3, y: 3)
                solidSquare.offset(x: 3, y: -3)
            } else {
                solidSquare.offset(x: -3, y: 3)
                dashedSquare.offset(x: 3, y: -3)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var solidSquare: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.black)
            .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.white, lineWidth: 1.7))
            .frame(width: 13, height: 13)
    }

    private var dashedSquare: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [2.4, 1.8]))
            )
            .frame(width: 13, height: 13)
    }
}

struct WallCanvasView: View {
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var voice: DonVoiceController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var ink = InkCanvasModel()
    @StateObject private var fitPic = FitPicController()
    @StateObject private var gifs = WallGIFStore()
    @StateObject private var photoBoothGIFs = WallGIFStore(scope: .photoBooth)
    @StateObject private var elements = WallElementStore()
    @StateObject private var photoBoothElements = WallElementStore(
        persistenceKey: "wall.photo-booth.element.transforms.v1"
    )
    @StateObject private var widgets = WallWidgetStore()
    @StateObject private var layers = WallLayerStore()
    @StateObject private var photoBoothLayers = WallLayerStore(
        persistenceKey: "wall.photo-booth.global-layers.v1"
    )
    @StateObject private var photoBoothVideo = PhotoBoothVideoModel()
    @StateObject private var goonCounter = GoonCounterModel(eventRecorder: GoonLogClient.shared)
    @StateObject private var goonIncrementEffect = GoonIncrementEffectController()
    @StateObject private var sonos = SonosNowPlayingService()
    @StateObject private var sonosRemote = WallSonosRemoteRelay()
    @StateObject private var cloud = WallCloudSyncController()
    @State private var showingSettings = false
    @State private var showingWidgetPicker = false
    @State private var showingGIFBrowser = false
    @State private var showingPhotoGallery = false
    @State private var showingPhotoBoothVideo = false
    @State private var showingPhotoBoothMusicPasscode = false
    @State private var showingMusicPanel = false
    @State private var musicPanelStartsInSearch = false
    @State private var isAdjustingSonosVolume = false
    @State private var isMovingGIF = false
    @State private var isMovingPhotoBoothGIF = false
    @State private var isEditingWall = false
    @State private var isEditingPhotoBooth = false
    @State private var isPhotoBoothMode = ProcessInfo.processInfo.arguments.contains("-PhotoBoothMode")

    var body: some View {
        GeometryReader { canvasProxy in
            ZStack {
                Color.white.ignoresSafeArea()

                if isPhotoBoothMode {
                    PhotoBoothVideoLoopView(model: photoBoothVideo)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if (isEditingWall && !isPhotoBoothMode || isEditingPhotoBooth && isPhotoBoothMode)
                    && !showingWidgetPicker
                    && !showingGIFBrowser
                    && !showingPhotoGallery
                    && !showingPhotoBoothVideo
                    && !showingMusicPanel
                    && !showingSettings {
                    WallEditTapBridge { point in
                        // Let an ordinary Button finish first. Its action marks
                        // the event so the wall observer cannot interpret the
                        // same tap as blank-canvas dismissal.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            if isPhotoBoothMode {
                                handlePhotoBoothEditTap(at: point, canvasSize: canvasProxy.size)
                            } else {
                                handleEditTap(at: point, canvasSize: canvasProxy.size)
                            }
                        }
                    }
                    .frame(width: canvasProxy.size.width, height: canvasProxy.size.height)
                    .allowsHitTesting(false)
                }

                if !isPhotoBoothMode {
                    EphemeralInkCanvas(model: ink)
                        .ignoresSafeArea()
                        .allowsHitTesting(ink.isDrawingEnabled && !isEditingWall)
                }

                if isPhotoBoothMode {
                    ForEach(photoBoothLayers.order, id: \.storageKey) { layer in
                        photoBoothLayer(layer, size: canvasProxy.size)
                            .zIndex(photoBoothLayers.zIndex(for: layer))
                    }
                } else {
                    ForEach(layers.order, id: \.storageKey) { layer in
                        wallLayer(layer, size: canvasProxy.size)
                            .zIndex(layers.zIndex(for: layer))
                    }

                }

                if isPhotoBoothMode && isEditingPhotoBooth {
                    photoBoothEditControls(size: canvasProxy.size)
                        .zIndex(75_000)
                } else if isEditingWall {
                    wallEditControls(size: canvasProxy.size)
                        .zIndex(75_000)
                }

                if isPhotoBoothMode {
                    PhotoBoothModeView(
                        controller: fitPic,
                        onOpenGallery: {
                            photoBoothVideo.refreshNow()
                            showingPhotoBoothVideo = true
                        },
                        onOpenMusic: {
                            showingPhotoBoothMusicPasscode = true
                        }
                    )
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .zIndex(isEditingPhotoBooth ? 50_000 : 70_000)
                }

                FitPicOverlayView(controller: fitPic)
                    .zIndex(80_000)

                if let prompt = fitPic.photoBoothEmailPrompt {
                    PhotoBoothEmailPromptView(prompt: prompt) {
                        fitPic.photoBoothEmailPrompt = nil
                    }
                    .wallAutoDismissModal {
                        fitPic.photoBoothEmailPrompt = nil
                    }
                    .zIndex(90_000)
                }

                if showingPhotoBoothMusicPasscode {
                    WallNativePasscodeGateView(
                        title: "MUSIC PASSCODE",
                        onCancel: { showingPhotoBoothMusicPasscode = false },
                        onUnlock: {
                            showingPhotoBoothMusicPasscode = false
                            openMusicPanel(searching: false)
                        }
                    )
                    .wallAutoDismissModal {
                        showingPhotoBoothMusicPasscode = false
                    }
                    .zIndex(95_000)
                }

                if !isPhotoBoothMode {
                    wallChrome
                        .zIndex(100_000)
                }

                if isEditingWall && !isPhotoBoothMode {
                    Text(editTransformState)
                        .font(.system(size: 1))
                        .opacity(0.001)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("wall.edit.transform-state")
                        .zIndex(150_000)
                }

                if !isPhotoBoothMode, goonCounter.isIdentityPickerPresented {
                    GoonIdentityOverlay(model: goonCounter) {
                        goonIncrementEffect.playThenCapture {
                            fitPic.triggerImmediateCapture()
                        }
                    }
                        .frame(width: canvasProxy.size.width, height: canvasProxy.size.height)
                        .zIndex(175_000)
                }

                if !isPhotoBoothMode, let celebration = goonCounter.celebration {
                    GoonSplashCelebration(celebration: celebration) {
                        goonCounter.finishCelebration(celebration.id)
                    }
                    .id(celebration.id)
                    .frame(width: canvasProxy.size.width, height: canvasProxy.size.height)
                    .zIndex(200_000)
                }

                VoicePresenceView()
                    .environmentObject(voice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                    .zIndex(300_000)

                WallThreeFingerSwipeBridge {
                    togglePhotoBoothMode()
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            }
            .coordinateSpace(name: "wall-canvas")
            .sheet(isPresented: $showingSettings) {
                WallSettingsView()
                    .environmentObject(voice)
                    .wallAutoDismissModal()
            }
            .sheet(isPresented: $showingWidgetPicker) {
                WallWidgetPicker(store: widgets, gifs: gifs, canvasSize: canvasProxy.size)
                    .wallAutoDismissModal()
            }
            .sheet(isPresented: $showingGIFBrowser) {
                GIFBrowserView(store: gifs)
                    .wallAutoDismissModal()
            }
            .sheet(isPresented: $showingPhotoGallery) {
                PhotoGalleryView()
                    .wallAutoDismissModal()
            }
            .fullScreenCover(isPresented: $showingPhotoBoothVideo) {
                PhotoBoothVideoGalleryView(model: photoBoothVideo)
                    .wallAutoDismissModal()
            }
            .sheet(isPresented: $showingMusicPanel) {
                WallMusicPanelView(
                    service: sonos,
                    startsFocusedOnSearch: musicPanelStartsInSearch
                )
                .wallAutoDismissModal()
            }
            .onChange(of: gifs.selectedID) { selected in
                if selected != nil {
                    elements.selectedID = nil
                    widgets.selectedID = nil
                }
            }
            .onChange(of: elements.selectedID) { selected in
                if selected != nil {
                    gifs.selectedID = nil
                    widgets.selectedID = nil
                }
            }
            .onChange(of: photoBoothGIFs.selectedID) { selected in
                if selected != nil { photoBoothElements.selectedID = nil }
            }
            .onChange(of: photoBoothElements.selectedID) { selected in
                if selected != nil { photoBoothGIFs.selectedID = nil }
            }
            .onChange(of: widgets.selectedID) { selected in
                if selected != nil {
                    gifs.selectedID = nil
                    elements.selectedID = nil
                }
            }
            .onChange(of: gifs.items.map(\.id)) { _ in synchronizeLayers() }
            .onChange(of: widgets.items.map(\.id)) { _ in synchronizeLayers() }
            .onChange(of: elements.stackingOrder) { _ in synchronizeLayers() }
            .onChange(of: photoBoothGIFs.items.map(\.id)) { _ in synchronizePhotoBoothLayers() }
            .onChange(of: photoBoothElements.stackingOrder) { _ in synchronizePhotoBoothLayers() }
            .onChange(of: isEditingWall) { editing in
                guard !editing else { return }
                elements.selectedID = nil
                gifs.selectedID = nil
                widgets.selectedID = nil
                isMovingGIF = false
            }
            .onChange(of: isEditingPhotoBooth) { editing in
                guard !editing else { return }
                photoBoothElements.selectedID = nil
                photoBoothGIFs.selectedID = nil
                isMovingPhotoBoothGIF = false
            }
            .onAppear {
                cloud.configure(
                    gifs: gifs,
                    photoBoothGIFs: photoBoothGIFs,
                    ink: ink,
                    elements: elements,
                    photoBoothElements: photoBoothElements,
                    widgets: widgets,
                    layers: layers,
                    photoBoothLayers: photoBoothLayers
                )
                cloud.start()
                sonosRemote.start(sonos: sonos)
                synchronizeLayers()
                photoBoothGIFs.seedPhotoBoothImportsIfNeeded(from: gifs)
                synchronizePhotoBoothLayers()
                photoBoothVideo.start()
                voice.onCancel = { [weak fitPic] in fitPic?.cancelCountdown() }
                fitPic.start()
                if ProcessInfo.processInfo.arguments.contains("-WallVerifySpotifySearch") {
                    openMusicPanel(searching: false)
                }
            }
            .onDisappear {
                cloud.stop()
                sonosRemote.stop()
                fitPic.stop()
                voice.onCancel = nil
            }
        }
    }

    private var editTransformState: String {
        if let id = elements.selectedID, let value = elements.transforms[id] {
            return "element:\(id.rawValue):x:\(value.normalizedX):y:\(value.normalizedY):scale:\(value.scale):rotation:\(value.rotationDegrees)"
        }
        if let id = gifs.selectedID, let item = gifs.items.first(where: { $0.id == id }) {
            return "gif:\(id.uuidString):x:\(item.normalizedX):y:\(item.normalizedY):scale:\(item.scale):rotation:\(item.rotationDegrees)"
        }
        if let id = widgets.selectedID, let item = widgets.items.first(where: { $0.id == id }) {
            return "widget:\(id.uuidString):x:\(item.normalizedX):y:\(item.normalizedY):scale:\(item.scale):rotation:\(item.rotationDegrees)"
        }
        return "none"
    }

    private var wallChrome: some View {
        VStack {
            Spacer()

            HStack(spacing: 8) {
                chromeIconButton(
                    symbol: "music.note",
                    label: "Open music controls",
                    identifier: "wall.music.button"
                ) {
                    openMusicPanel(searching: false)
                }

                FitPicCameraButton(controller: fitPic)
                PhotoGalleryButton { showingPhotoGallery = true }

                chromeIconButton(
                    symbol: "gearshape",
                    label: "Wall settings",
                    identifier: "wall.settings.button"
                ) {
                    showingSettings = true
                }

                InkControlsView(model: ink)

                chromeIconButton(
                    symbol: "plus",
                    label: "Open Wall edit menu",
                    identifier: "wall.widget.add"
                ) {
                    enterEditMode()
                    showingWidgetPicker = true
                }

                if isEditingWall {
                    chromeIconButton(
                        symbol: "checkmark",
                        label: "Finish editing Wall",
                        identifier: "wall.edit.done",
                        action: exitEditMode
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.bottom, 18)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func chromeIconButton(
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
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 58, height: 54)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func enterEditMode() {
        guard !showingSettings, !showingGIFBrowser,
              !showingPhotoGallery, !showingMusicPanel else { return }
        guard !isEditingWall else { return }
        ink.cancelActiveGesture()
        if ink.isDrawingEnabled { ink.toggleDrawingMode() }
        isEditingWall = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func beginEditing(_ layer: WallLayerID) {
        guard !showingSettings, !showingGIFBrowser, !showingPhotoGallery,
              !showingMusicPanel, !showingWidgetPicker,
              !goonCounter.isIdentityPickerPresented else { return }
        ink.cancelActiveGesture()
        if ink.isDrawingEnabled { ink.toggleDrawingMode() }
        isEditingWall = true

        switch layer {
        case let .element(id):
            elements.selectedID = id
        case let .gif(id):
            gifs.selectedID = id
        case let .widget(id):
            widgets.selectedID = id
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func handleEditTap(at point: CGPoint, canvasSize: CGSize) {
        guard isEditingWall, !isMovingGIF else { return }
        guard !showingWidgetPicker, !showingGIFBrowser,
              !showingPhotoGallery, !showingMusicPanel,
              !showingSettings else { return }
        guard Date().timeIntervalSince(layers.lastControlInteraction) > 0.18 else { return }

        let target = layers.order.reversed().first { layer in
            switch layer {
            case let .element(id):
                return elements.contains(id, point: point)
            case let .gif(id):
                return gifs.contains(id, point: point, in: canvasSize)
            case let .widget(id):
                return widgets.contains(id, point: point, in: canvasSize)
            }
        }

        if let target {
            guard target != selectedLayer else { return }
            beginEditing(target)
        } else {
            exitEditMode()
        }
    }

    private var selectedLayer: WallLayerID? {
        if let id = elements.selectedID { return .element(id) }
        if let id = gifs.selectedID { return .gif(id) }
        if let id = widgets.selectedID { return .widget(id) }
        return nil
    }

    private func exitEditMode() {
        isEditingWall = false
        showingWidgetPicker = false
    }

    private func beginEditingPhotoBooth(_ layer: WallLayerID) {
        guard isPhotoBoothMode, !showingPhotoBoothVideo else { return }
        isEditingPhotoBooth = true
        switch layer {
        case let .element(id):
            photoBoothElements.selectedID = id
        case let .gif(id):
            photoBoothGIFs.selectedID = id
        case .widget:
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func handlePhotoBoothEditTap(at point: CGPoint, canvasSize: CGSize) {
        guard isEditingPhotoBooth, !isMovingPhotoBoothGIF else { return }
        guard Date().timeIntervalSince(photoBoothLayers.lastControlInteraction) > 0.18 else { return }
        let target = photoBoothLayers.order.reversed().first { layer in
            switch layer {
            case let .element(id):
                return id == .clock && photoBoothElements.contains(id, point: point)
            case let .gif(id):
                return photoBoothGIFs.contains(id, point: point, in: canvasSize)
            case .widget:
                return false
            }
        }
        if let target {
            if target != selectedPhotoBoothLayer { beginEditingPhotoBooth(target) }
        } else {
            isEditingPhotoBooth = false
        }
    }

    private var selectedPhotoBoothLayer: WallLayerID? {
        if let id = photoBoothElements.selectedID { return .element(id) }
        if let id = photoBoothGIFs.selectedID { return .gif(id) }
        return nil
    }

    private func togglePhotoBoothMode() {
        guard !showingSettings, !showingWidgetPicker,
              !showingGIFBrowser, !showingPhotoGallery,
              !showingMusicPanel else { return }
        if !isPhotoBoothMode {
            exitEditMode()
            ink.cancelActiveGesture()
            if ink.isDrawingEnabled { ink.toggleDrawingMode() }
        } else {
            isEditingPhotoBooth = false
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 1)) {
            isPhotoBoothMode.toggle()
        }
    }

    private func openMusicPanel(searching: Bool) {
        layers.noteControlInteraction()
        musicPanelStartsInSearch = searching
        showingMusicPanel = true
    }

    private func synchronizeLayers() {
        layers.synchronize(with:
            gifs.items.map { .gif($0.id) }
                + widgets.items.map { .widget($0.id) }
                + [
                    .element(.clock), .element(.weather), .element(.transit),
                    .element(.note), .element(.goonCounter), .element(.sonosNowPlaying)
                ]
        )
    }

    private func synchronizePhotoBoothLayers() {
        photoBoothLayers.synchronize(with:
            photoBoothGIFs.items.map { .gif($0.id) } + [.element(.clock)]
        )
    }

    @ViewBuilder
    private func wallLayer(_ layer: WallLayerID, size: CGSize) -> some View {
        switch layer {
        case let .gif(id):
            if let item = gifs.items.first(where: { $0.id == id }), let data = gifs.data(for: item) {
                EditableGIFDecoration(
                    item: item,
                    data: data,
                    containerSize: size,
                    store: gifs,
                    layers: layers,
                    ink: ink,
                    isManipulatingAnyDecoration: $isMovingGIF,
                    isEditing: $isEditingWall,
                    onRequestEdit: { beginEditing(.gif(id)) }
                )
            }
        case let .widget(id):
            if let item = widgets.items.first(where: { $0.id == id }) {
                WallWidgetElement(
                    item: item,
                    store: widgets,
                    layers: layers,
                    dashboard: dashboard,
                    voice: voice,
                    isEditing: $isEditingWall,
                    containerSize: size,
                    onRequestEdit: { beginEditing(.widget(id)) },
                    onInteractionChanged: { isMovingGIF = $0 }
                )
                .allowsHitTesting(isEditingWall || !ink.isDrawingEnabled)
            }
        case let .element(id):
            if id == .clock {
                movableClock(size: size)
            } else {
                movableElement(id, size: size)
            }
        }
    }

    @ViewBuilder
    private func photoBoothLayer(_ layer: WallLayerID, size: CGSize) -> some View {
        switch layer {
        case let .gif(id):
            if let item = photoBoothGIFs.items.first(where: { $0.id == id }),
               let data = photoBoothGIFs.data(for: item) {
                EditableGIFDecoration(
                    item: item,
                    data: data,
                    containerSize: size,
                    store: photoBoothGIFs,
                    layers: photoBoothLayers,
                    ink: ink,
                    isManipulatingAnyDecoration: $isMovingPhotoBoothGIF,
                    isEditing: $isEditingPhotoBooth,
                    onRequestEdit: { beginEditingPhotoBooth(.gif(id)) }
                )
            }
        case .element(.clock):
            movablePhotoBoothClock(size: size)
        case .element, .widget:
            EmptyView()
        }
    }

    @ViewBuilder
    private func wallEditControls(size: CGSize) -> some View {
        if let id = gifs.selectedID, let item = gifs.items.first(where: { $0.id == id }) {
            GIFEditControlBar(item: item, containerSize: size, store: gifs, layers: layers)
        } else if let id = widgets.selectedID, let item = widgets.items.first(where: { $0.id == id }) {
            WallWidgetEditControls(item: item, store: widgets, layers: layers, containerSize: size)
        } else if let id = elements.selectedID, let layout = wallElementLayout(id, size: size) {
            WallElementEditControls(
                id: id,
                baseSize: layout.size,
                defaultCenter: layout.center,
                containerSize: size,
                store: elements,
                layers: layers
            )
        }
    }

    @ViewBuilder
    private func photoBoothEditControls(size: CGSize) -> some View {
        if let id = photoBoothGIFs.selectedID,
           let item = photoBoothGIFs.items.first(where: { $0.id == id }) {
            GIFEditControlBar(
                item: item,
                containerSize: size,
                store: photoBoothGIFs,
                layers: photoBoothLayers
            )
        } else if photoBoothElements.selectedID == .clock {
            let layout = clockLayout(size: size)
            WallElementEditControls(
                id: .clock,
                baseSize: layout.size,
                defaultCenter: layout.center,
                containerSize: size,
                store: photoBoothElements,
                layers: photoBoothLayers
            )
        }
    }

    private func clockLayout(size: CGSize) -> (size: CGSize, center: CGPoint) {
        let landscape = size.width > size.height
        let clockSize = CGSize(width: min(650, size.width - 64), height: 230)
        return (
            clockSize,
            CGPoint(x: landscape ? 32 + clockSize.width / 2 : size.width / 2, y: 32 + clockSize.height / 2)
        )
    }

    private func movableClock(size: CGSize) -> some View {
        let layout = clockLayout(size: size)
        return MovableWallElement(
            id: .clock,
            baseSize: layout.size,
            defaultCenter: layout.center,
            containerSize: size,
            allowsDrawingThrough: true,
            store: elements,
            layers: layers,
            ink: ink,
            isManipulatingAnyElement: $isMovingGIF,
            isEditing: $isEditingWall,
            onRequestEdit: { beginEditing(.element(.clock)) }
        ) {
            WallClockView()
                .allowsHitTesting(false)
        }
    }

    private func movablePhotoBoothClock(size: CGSize) -> some View {
        let layout = clockLayout(size: size)
        return MovableWallElement(
            id: .clock,
            baseSize: layout.size,
            defaultCenter: layout.center,
            containerSize: size,
            allowsDrawingThrough: false,
            store: photoBoothElements,
            layers: photoBoothLayers,
            ink: ink,
            isManipulatingAnyElement: $isMovingPhotoBoothGIF,
            isEditing: $isEditingPhotoBooth,
            onRequestEdit: { beginEditingPhotoBooth(.element(.clock)) }
        ) {
            WallClockView()
                .allowsHitTesting(false)
        }
    }

    private func wallElementLayout(_ id: WallElementID, size: CGSize) -> (size: CGSize, center: CGPoint)? {
        if id == .clock { return clockLayout(size: size) }
        let landscape = size.width > size.height
        let weatherSize = CGSize(width: min(360, size.width - 64), height: 82)
        let weatherCenter = CGPoint(x: 32 + weatherSize.width / 2, y: 304)
        let scopedTransitAlerts = WallTransitScope.alerts(from: dashboard.transitAlerts)
        let transitSize = CGSize(
            width: min(660, size.width - 64),
            height: max(26, CGFloat(max(scopedTransitAlerts.count, 1)) * 26)
        )
        let transitTop = weatherCenter.y + weatherSize.height / 2 + 12
        let transitCenter = CGPoint(
            x: 32 + transitSize.width / 2,
            y: transitTop + transitSize.height / 2
        )
        let noteSize = CGSize(
            width: landscape ? max(260, size.width * 0.34) : max(280, size.width - 64),
            height: landscape ? max(270, size.height * 0.48) : 270
        )
        let noteCenter = CGPoint(
            x: landscape ? size.width - noteSize.width / 2 - 32 : size.width / 2,
            y: landscape ? noteSize.height / 2 + 32 : 500
        )
        let goonSize = CGSize(width: 310, height: 244)
        let goonCenter = CGPoint(
            x: landscape ? size.width - goonSize.width / 2 - 32 : size.width / 2,
            y: size.height - goonSize.height / 2 - 28
        )
        let sonosSize = SonosNowPlayingWidget.preferredSize
        let sonosCenter = CGPoint(
            x: landscape ? 32 + sonosSize.width / 2 : size.width / 2,
            y: landscape
                ? size.height - 108 - sonosSize.height / 2
                : size.height - 280 - sonosSize.height / 2
        )

        switch id {
        case .weather: return (weatherSize, weatherCenter)
        case .transit: return (transitSize, transitCenter)
        case .note: return (noteSize, noteCenter)
        case .goonCounter: return (goonSize, goonCenter)
        case .sonosNowPlaying: return (sonosSize, sonosCenter)
        case .clock, .mediaControls, .toolControls: return nil
        }
    }

    @ViewBuilder
    private func movableElement(_ id: WallElementID, size: CGSize) -> some View {
        if let layout = wallElementLayout(id, size: size) {
            switch id {
            case .weather:
            MovableWallElement(
                id: .weather,
                baseSize: layout.size,
                defaultCenter: layout.center,
                containerSize: size,
                allowsDrawingThrough: true,
                store: elements,
                layers: layers,
                ink: ink,
                isManipulatingAnyElement: $isMovingGIF,
                isEditing: $isEditingWall,
                onRequestEdit: { beginEditing(.element(.weather)) }
            ) {
                WeatherSignalView(snapshot: dashboard.weather)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }

            case .transit:
            MovableWallElement(
                id: .transit,
                baseSize: layout.size,
                defaultCenter: layout.center,
                containerSize: size,
                allowsDrawingThrough: true,
                store: elements,
                layers: layers,
                ink: ink,
                isManipulatingAnyElement: $isMovingGIF,
                isEditing: $isEditingWall,
                onRequestEdit: { beginEditing(.element(.transit)) }
            ) {
                TransitTickerView(alerts: dashboard.transitAlerts)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }

            case .note:
            MovableWallElement(
                id: .note,
                baseSize: layout.size,
                defaultCenter: layout.center,
                containerSize: size,
                allowsDrawingThrough: false,
                store: elements,
                layers: layers,
                ink: ink,
                isManipulatingAnyElement: $isMovingGIF,
                isEditing: $isEditingWall,
                onRequestEdit: { beginEditing(.element(.note)) }
            ) {
                NoteCanvasView()
            }

            case .goonCounter:
            MovableWallElement(
                id: .goonCounter,
                baseSize: layout.size,
                defaultCenter: layout.center,
                containerSize: size,
                allowsDrawingThrough: false,
                allowsSelectedContentInteraction: true,
                selectedContentInteractionExclusionTrailing: 96,
                store: elements,
                layers: layers,
                ink: ink,
                isManipulatingAnyElement: $isMovingGIF,
                isEditing: $isEditingWall,
                onRequestEdit: { beginEditing(.element(.goonCounter)) }
            ) {
                GoonCounterView(
                    model: goonCounter,
                    onControlInteraction: layers.noteControlInteraction
                )
            }

            case .sonosNowPlaying:
            MovableWallElement(
                id: .sonosNowPlaying,
                baseSize: layout.size,
                defaultCenter: layout.center,
                containerSize: size,
                allowsDrawingThrough: false,
                store: elements,
                layers: layers,
                ink: ink,
                isManipulatingAnyElement: $isMovingGIF,
                isEditing: $isEditingWall,
                onRequestEdit: {
                    guard !isAdjustingSonosVolume else { return }
                    beginEditing(.element(.sonosNowPlaying))
                }
            ) {
                SonosNowPlayingWidget(
                    service: sonos,
                    onOpen: { openMusicPanel(searching: false) },
                    onSearch: { openMusicPanel(searching: true) },
                    onVolumeInteractionChanged: { editing in
                        if editing {
                            isAdjustingSonosVolume = true
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                isAdjustingSonosVolume = false
                            }
                        }
                    }
                )
            }

            case .clock, .mediaControls, .toolControls:
                EmptyView()
            }
        }
    }
}
