import CryptoKit
import ImageIO
import SwiftUI
import UIKit
import WebKit

struct WallGalleryPhoto: Identifiable {
    let name: String
    let created: String
    let url: URL

    var id: String { name }
}

private enum WallPhotoAPI {
    static let baseURL = WallConfiguration.serverURL

    static func requestData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 25
        request.setValue("Bearer \(KeychainToken.getOrCreate())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              200..<300 ~= response.statusCode else { throw URLError(.badServerResponse) }
        return data
    }

    static func image(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

enum WallPhotoEditStorage {
    static let didChangeNotification = Notification.Name("WallPhotoEditDidChange")

    static func notifyChanged() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func identifier(for photoName: String) -> String {
        SHA256.hash(data: Data(photoName.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func directoryURL(
        for photoName: String,
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Wall/PhotoEdits", isDirectory: true)
            .appendingPathComponent(identifier(for: photoName), isDirectory: true)
    }

    static func register(photoName: String, fileManager: FileManager = .default) {
        guard let directory = directoryURL(for: photoName, fileManager: fileManager) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(photoName.utf8).write(
            to: directory.appendingPathComponent("photo-name.txt"),
            options: .atomic
        )
    }

    static func cloudSnapshot(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> (records: [[String: Any]], assets: [(record: WallCloudGIFRecord, data: Data)]) {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Wall/PhotoEdits", isDirectory: true),
              let directories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return ([], []) }

        var records: [[String: Any]] = []
        var assets: [(record: WallCloudGIFRecord, data: Data)] = []
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let identifier = directory.lastPathComponent
            guard identifier.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let photoNameData = try? Data(contentsOf: directory.appendingPathComponent("photo-name.txt")),
                  let photoName = String(data: photoNameData, encoding: .utf8),
                  Self.identifier(for: photoName) == identifier else { continue }

            let gifDirectory = directory.appendingPathComponent("GIFs", isDirectory: true)
            let metadataURL = gifDirectory.appendingPathComponent("wall-gifs.json")
            let items = (try? Data(contentsOf: metadataURL))
                .flatMap { try? JSONDecoder().decode([WallGIFItem].self, from: $0) } ?? []
            let gifPairs: [(record: WallCloudGIFRecord, data: Data)] = items.compactMap { item in
                guard case let .downloaded(filename) = item.source,
                      !filename.contains("/"), !filename.contains("\\"), !filename.contains(".."),
                      let data = try? Data(contentsOf: gifDirectory.appendingPathComponent(filename)) else {
                    return nil
                }
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
            assets.append(contentsOf: gifPairs)
            let gifs = (try? JSONSerialization.jsonObject(
                with: JSONEncoder().encode(gifPairs.map(\.record))
            )) ?? []
            let drawingsURL = directory.appendingPathComponent("drawings.json")
            let drawings = (try? Data(contentsOf: drawingsURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            let layers = defaults.stringArray(
                forKey: "wall.photo-edit.\(identifier).layers.v1"
            ) ?? []
            records.append([
                "id": identifier,
                "photoName": photoName,
                "drawings": drawings,
                "gifs": gifs,
                "layers": layers,
            ])
        }
        return (records, assets)
    }

    static func applyCloudSnapshot(
        _ records: [[String: Any]],
        assets: [String: Data],
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        for record in records.prefix(500) {
            guard let identifier = record["id"] as? String,
                  identifier.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let photoName = record["photoName"] as? String,
                  Self.identifier(for: photoName) == identifier,
                  let directory = directoryURL(for: photoName, fileManager: fileManager) else { continue }
            register(photoName: photoName, fileManager: fileManager)
            if let drawings = record["drawings"],
               JSONSerialization.isValidJSONObject(drawings),
               let data = try? JSONSerialization.data(withJSONObject: drawings) {
                try? data.write(to: directory.appendingPathComponent("drawings.json"), options: .atomic)
            }
            if let gifs = record["gifs"],
               let data = try? JSONSerialization.data(withJSONObject: gifs),
               let decoded = try? JSONDecoder().decode([WallCloudGIFRecord].self, from: data) {
                let gifDirectory = directory.appendingPathComponent("GIFs", isDirectory: true)
                try? fileManager.createDirectory(at: gifDirectory, withIntermediateDirectories: true)
                let items: [WallGIFItem] = decoded.compactMap { gif in
                    guard gif.asset.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                          let gifData = assets[gif.asset],
                          SHA256.hash(data: gifData).map({ String(format: "%02x", $0) }).joined() == gif.asset else {
                        return nil
                    }
                    let filename = "cloud-\(gif.asset).gif"
                    try? gifData.write(to: gifDirectory.appendingPathComponent(filename), options: .atomic)
                    return WallGIFItem(
                        id: gif.id,
                        source: .downloaded(filename),
                        naturalWidth: gif.naturalWidth,
                        naturalHeight: gif.naturalHeight,
                        normalizedX: gif.normalizedX,
                        normalizedY: gif.normalizedY,
                        scale: gif.scale,
                        rotationDegrees: gif.rotationDegrees
                    )
                }
                if let metadata = try? JSONEncoder().encode(items) {
                    try? metadata.write(
                        to: gifDirectory.appendingPathComponent("wall-gifs.json"),
                        options: .atomic
                    )
                }
            }
            if let layers = record["layers"] as? [String] {
                defaults.set(layers, forKey: "wall.photo-edit.\(identifier).layers.v1")
            }
        }
    }
}

@MainActor
private final class WallPhotoEditorModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var loadFailed = false
    private let photo: WallGalleryPhoto

    init(photo: WallGalleryPhoto) {
        self.photo = photo
    }

    func loadFullImage() {
        Task {
            do {
                let data = try await WallPhotoAPI.requestData(photo.url)
                guard let fullImage = WallPhotoAPI.image(from: data, maxPixelSize: 2_400) else {
                    throw URLError(.cannotDecodeContentData)
                }
                image = fullImage
                loadFailed = false
            } catch {
                loadFailed = true
            }
        }
    }
}

struct PhotoGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: WallGalleryPhoto?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WALL PHOTOS")
                    .font(.custom("Helvetica", size: 15).weight(.bold))
                    .tracking(0.5)
                Spacer()
                InstantActionButton(action: { dismiss() }) {
                    Text("DONE")
                        .font(.custom("Helvetica", size: 13).weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color.black)
                }
                .accessibilityLabel("Close photo gallery")
                .accessibilityIdentifier("wall.gallery.done")
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            Rectangle()
                .fill(Color.black)
                .frame(height: 1)

            WallPhotoWorkspaceWebView { name, created in
                let url = WallPhotoAPI.baseURL
                    .appendingPathComponent("api/device/photos")
                    .appendingPathComponent(name)
                selectedPhoto = WallGalleryPhoto(name: name, created: created, url: url)
            }
        }
        .background(Color.white)
        .preferredColorScheme(.light)
        .fullScreenCover(item: $selectedPhoto) { photo in
            WallPhotoEditorView(photo: photo)
        }
    }
}

private struct WallPhotoWorkspaceWebView: UIViewRepresentable {
    let onEditPhoto: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEditPhoto: onEditPhoto) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "wallPhotoEdit")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.load(URLRequest(url: WallPhotoAPI.baseURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "wallPhotoEdit")
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onEditPhoto: (String, String) -> Void

        init(onEditPhoto: @escaping (String, String) -> Void) {
            self.onEditPhoto = onEditPhoto
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "wallPhotoEdit",
                  let body = message.body as? [String: Any],
                  let name = body["name"] as? String,
                  name.hasPrefix("fit-"), name.hasSuffix(".jpg"),
                  !name.contains("/"), !name.contains("\\"), !name.contains("..") else { return }
            onEditPhoto(name, body["created"] as? String ?? "")
        }
    }
}

struct PhotoGalleryButton: View {
    let action: () -> Void

    var body: some View {
        InstantActionButton(action: action) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.white)
                .frame(width: 58, height: 54)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .accessibilityLabel("Open photo gallery")
        .accessibilityIdentifier("wall.gallery.button")
    }
}

struct WallPhotoEditorView: View {
    let photo: WallGalleryPhoto

    @Environment(\.dismiss) private var dismiss
    @StateObject private var photoModel: WallPhotoEditorModel
    @StateObject private var ink: InkCanvasModel
    @StateObject private var gifs: WallGIFStore
    @StateObject private var layers: WallLayerStore
    @State private var showingGIFBrowser = false
    @State private var isEditing = true
    @State private var isManipulatingGIF = false

    init(photo: WallGalleryPhoto) {
        self.photo = photo
        let identifier = WallPhotoEditStorage.identifier(for: photo.name)
        let directory = WallPhotoEditStorage.directoryURL(for: photo.name)
        WallPhotoEditStorage.register(photoName: photo.name)
        _photoModel = StateObject(wrappedValue: WallPhotoEditorModel(photo: photo))
        _ink = StateObject(wrappedValue: InkCanvasModel(
            persistenceURL: directory?.appendingPathComponent("drawings.json"),
            onPersist: WallPhotoEditStorage.notifyChanged
        ))
        _gifs = StateObject(wrappedValue: WallGIFStore(
            scope: .photo(identifier),
            onPersist: WallPhotoEditStorage.notifyChanged
        ))
        _layers = StateObject(wrappedValue: WallLayerStore(
            persistenceKey: "wall.photo-edit.\(identifier).layers.v1"
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PHOTO")
                    .font(.custom("Helvetica-Bold", size: 15))
                    .tracking(0.5)
                Spacer()
                InstantActionButton(action: { dismiss() }) {
                    Text("DONE")
                        .font(.custom("Helvetica-Bold", size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color.black)
                }
                .accessibilityIdentifier("wall.photo-editor.done")
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            Rectangle().fill(Color.black).frame(height: 1)

            GeometryReader { proxy in
                if let image = photoModel.image {
                    let canvasSize = fittedSize(image.size, inside: proxy.size)
                    ZStack {
                        Color.white

                        ZStack {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: canvasSize.width, height: canvasSize.height)
                                .allowsHitTesting(false)

                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { gifs.selectedID = nil }

                            EphemeralInkCanvas(model: ink)
                                .allowsHitTesting(ink.isDrawingEnabled)

                            WallGIFDecorations(
                                store: gifs,
                                layers: layers,
                                containerSize: canvasSize,
                                ink: ink,
                                isManipulatingDecoration: $isManipulatingGIF,
                                isEditing: $isEditing,
                                onRequestEdit: { gifs.selectedID = $0 }
                            )
                        }
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .clipped()
                        .coordinateSpace(name: "wall-canvas")

                        HStack(alignment: .bottom, spacing: 8) {
                            InstantActionButton(action: { showingGIFBrowser = true }) {
                                Text(".gif")
                                    .font(.custom("Helvetica-Bold", size: 15))
                                    .foregroundColor(.white)
                                    .frame(width: 58, height: 54)
                                    .background(Color.black)
                            }
                            .accessibilityLabel("Add GIF to photo")
                            .accessibilityIdentifier("wall.photo-editor.gif")

                            InkControlsView(model: ink)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(18)
                    }
                } else if photoModel.loadFailed {
                    InstantActionButton(action: photoModel.loadFullImage) {
                        Text("RETRY")
                            .font(.custom("Helvetica-Bold", size: 13))
                            .foregroundColor(.white)
                            .frame(width: 88, height: 44)
                            .background(Color.black)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Retry loading photo")
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.white)
        .preferredColorScheme(.light)
        .onAppear {
            synchronizeLayers()
            photoModel.loadFullImage()
        }
        .onChange(of: gifs.items.map(\.id)) { _ in synchronizeLayers() }
        .onChange(of: layers.order.map(\.storageKey)) { _ in
            WallPhotoEditStorage.notifyChanged()
        }
        .onChange(of: gifs.addedCount) { _ in
            synchronizeLayers()
            gifs.selectedID = gifs.items.last?.id
        }
        .sheet(isPresented: $showingGIFBrowser) {
            GIFBrowserView(store: gifs)
                .wallAutoDismissModal()
        }
    }

    private func synchronizeLayers() {
        layers.synchronize(with: gifs.items.map { .gif($0.id) })
    }

    private func fittedSize(_ imageSize: CGSize, inside bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
