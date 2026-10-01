import ImageIO
import SwiftUI
import UIKit

enum PhotoBoothNight {
    static func identifier(
        for date: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "America/New_York")!
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct PhotoBoothPhotoIndex: Decodable {
    let photos: [PhotoBoothPhotoRecord]
}

private struct PhotoBoothPhotoRecord: Decodable {
    let name: String
    let url: String
}

struct PhotoBoothPhoto: Identifiable {
    let name: String
    let image: UIImage
    var id: String { name }
}

@MainActor
final class PhotoBoothVideoModel: ObservableObject {
    @Published private(set) var currentFrame: UIImage?
    @Published private(set) var frameCount = 0
    @Published private(set) var photos: [PhotoBoothPhoto] = []
    @Published private(set) var deletionError = ""

    private var frames: [UIImage] = []
    private var frameIndex = 0
    private var loopTimer: Timer?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var isStarted = false
    private let baseURL = WallConfiguration.serverURL

    deinit {
        loopTimer?.invalidate()
        refreshTimer?.invalidate()
        refreshTask?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        startLoopTimer()
        refreshTask = Task { await refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    private func startLoopTimer() {
        loopTimer?.invalidate()
        loopTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceFrame() }
        }
    }

    private func advanceFrame() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        currentFrame = frames[frameIndex]
    }

    private func refresh() async {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/device/photo-booth"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "night", value: PhotoBoothNight.identifier())]
        guard let indexURL = components.url else { return }
        do {
            let indexData = try await requestData(indexURL)
            let records = try JSONDecoder().decode(PhotoBoothPhotoIndex.self, from: indexData).photos
            var loaded: [PhotoBoothPhoto] = []
            loaded.reserveCapacity(records.count)
            for record in records {
                guard !Task.isCancelled,
                      let url = URL(string: record.url, relativeTo: baseURL)?.absoluteURL,
                      let image = Self.thumbnail(from: try await requestData(url)) else { continue }
                loaded.append(PhotoBoothPhoto(name: record.name, image: image))
            }
            guard !Task.isCancelled else { return }
            photos = loaded
            frames = loaded.map(\.image)
            frameCount = loaded.count
            frameIndex = min(frameIndex, max(0, loaded.count - 1))
            currentFrame = frames.indices.contains(frameIndex) ? frames[frameIndex] : nil
        } catch {
            // Keep the last usable reel visible through brief Wi-Fi gaps.
        }
    }

    func delete(_ photo: PhotoBoothPhoto) async {
        let deleteURL = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("device")
            .appendingPathComponent("photo-booth")
            .appendingPathComponent("photos")
            .appendingPathComponent(photo.name)
        guard var components = URLComponents(
            url: deleteURL,
            resolvingAgainstBaseURL: false
        ) else { return }
        components.queryItems = [URLQueryItem(name: "night", value: PhotoBoothNight.identifier())]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("Bearer \(KeychainToken.getOrCreate())", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                throw URLError(.badServerResponse)
            }
            photos.removeAll { $0.name == photo.name }
            frames = photos.map(\.image)
            frameCount = frames.count
            frameIndex = min(frameIndex, max(0, frames.count - 1))
            currentFrame = frames.indices.contains(frameIndex) ? frames[frameIndex] : nil
            deletionError = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            deletionError = "COULDN’T DELETE PHOTO"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func requestData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(KeychainToken.getOrCreate())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func thumbnail(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 960
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct PhotoBoothVideoLoopView: View {
    @ObservedObject var model: PhotoBoothVideoModel
    var fillsScreen = true

    var body: some View {
        ZStack {
            Color.white
            if let frame = model.currentFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: fillsScreen ? .fill : .fit)
                    .saturation(0)
            }
        }
        .clipped()
        .accessibilityLabel("Tonight's Photo Booth video, \(model.frameCount) frames")
        .onAppear { model.start() }
    }
}

/// App-native four-digit keypad shared by protected Photo Booth surfaces. It
/// never focuses a text field, so the software keyboard cannot cover or delay
/// the protected action.
struct WallNativePasscodeGateView: View {
    let title: String
    let onCancel: () -> Void
    let onUnlock: () -> Void

    @State private var digits = ""
    @State private var failed = false
    private let expectedCode = (Bundle.main.object(forInfoDictionaryKey: "WallLocalPasscode") as? String ?? "")
    private let columns = Array(repeating: GridItem(.fixed(72), spacing: 10), count: 3)

    var body: some View {
        ZStack {
            Color.white.opacity(0.97).ignoresSafeArea()

            VStack(spacing: 18) {
                Text(title)
                    .font(.custom("Helvetica-Bold", size: 14))

                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < digits.count ? Color.black : Color.clear)
                            .overlay(Circle().stroke(failed ? Color.red : Color.black, lineWidth: 2))
                            .frame(width: 15, height: 15)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(digits.count) of 4 digits entered")

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(1...9, id: \.self) { digit in
                        digitButton(digit)
                    }

                    InstantActionButton(action: onCancel) {
                        Text("CANCEL")
                            .font(.custom("Helvetica-Bold", size: 10))
                            .foregroundColor(.black)
                            .frame(width: 72, height: 54)
                    }
                    .accessibilityIdentifier("wall.passcode.cancel")

                    digitButton(0)

                    InstantActionButton {
                        guard !digits.isEmpty else { return }
                        digits.removeLast()
                        failed = false
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 72, height: 54)
                    }
                    .accessibilityLabel("Delete digit")
                    .accessibilityIdentifier("wall.passcode.delete")
                }
            }
            .padding(24)
            .background(Color.white)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wall.passcode.keypad")
    }

    private func digitButton(_ digit: Int) -> some View {
        InstantActionButton {
            guard digits.count < expectedCode.count else { return }
            failed = false
            digits.append(String(digit))
            UISelectionFeedbackGenerator().selectionChanged()
            guard digits.count == expectedCode.count else { return }
            if digits == expectedCode {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onUnlock()
            } else {
                failed = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    digits = ""
                    failed = false
                }
            }
        } label: {
            Text(String(digit))
                .font(.custom("Helvetica-Bold", size: 24))
                .foregroundColor(.white)
                .frame(width: 72, height: 54)
                .background(Color.black)
        }
        .accessibilityLabel(String(digit))
        .accessibilityIdentifier("wall.passcode.digit.\(digit)")
    }
}

struct PhotoBoothVideoGalleryView: View {
    @ObservedObject var model: PhotoBoothVideoModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .video
    @State private var galleryUnlocked = false
    @State private var showingPasscode = false

    private enum Tab { case video, gallery }

    var body: some View {
        ZStack {
            PhotoBoothVideoLoopView(model: model, fillsScreen: false)
                .ignoresSafeArea()

            if tab == .gallery && galleryUnlocked {
                partyGallery
                    .transition(.opacity)
            }

            VStack {
                HStack(spacing: 8) {
                    tabButton("VIDEO", selected: tab == .video) {
                        tab = .video
                    }
                    tabButton("GALLERY", selected: tab == .gallery) {
                        if galleryUnlocked {
                            tab = .gallery
                        } else {
                            showingPasscode = true
                        }
                    }

                    Spacer()

                    InstantActionButton(action: { dismiss() }) {
                        Text("DONE")
                            .font(.custom("Helvetica-Bold", size: 13))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(Color.black)
                    }
                    .accessibilityIdentifier("wall.photo-booth.gallery.done")
                }
                .padding(18)

                Spacer()
            }

            if showingPasscode {
                WallNativePasscodeGateView(
                    title: "GALLERY PASSCODE",
                    onCancel: { showingPasscode = false },
                    onUnlock: {
                        galleryUnlocked = true
                        showingPasscode = false
                        tab = .gallery
                    }
                )
            }
        }
        .background(Color.white)
        .preferredColorScheme(.light)
    }

    private var partyGallery: some View {
        ZStack {
            Color.white.opacity(0.94).ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    ForEach(model.photos) { photo in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: photo.image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 190)
                                .clipped()

                            InstantActionButton {
                                Task { await model.delete(photo) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.black)
                            }
                            .accessibilityLabel("Delete party photo")
                            .accessibilityIdentifier("wall.photo-booth.delete.\(photo.name)")
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 76)
                .padding(.bottom, 18)

                if !model.deletionError.isEmpty {
                    Text(model.deletionError)
                        .font(.custom("Helvetica-Bold", size: 12))
                        .padding(.bottom, 18)
                }
            }
        }
    }

    private func tabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        InstantActionButton(action: action) {
            Text(title)
                .font(.custom("Helvetica-Bold", size: 13))
                .foregroundColor(selected ? .white : .black)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(selected ? Color.black : Color.white)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
        }
    }
}
