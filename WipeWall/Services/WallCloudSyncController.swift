import Combine
import Foundation

@MainActor
final class WallCloudSyncController: ObservableObject {
    @Published private(set) var status = "local"

    private let baseURL = WallConfiguration.serverURL
    private let defaults = UserDefaults.standard
    private var gifs: WallGIFStore?
    private var photoBoothGIFs: WallGIFStore?
    private var ink: InkCanvasModel?
    private var elements: WallElementStore?
    private var photoBoothElements: WallElementStore?
    private var widgets: WallWidgetStore?
    private var layers: WallLayerStore?
    private var photoBoothLayers: WallLayerStore?
    private var cancellables: Set<AnyCancellable> = []
    private var pollingTask: Task<Void, Never>?
    private var isApplying = false
    private var isReady = false
    private var isDirty = false
    private var photoEditsDirty = false
    private var revision = 0
    private let snapshotInterval: TimeInterval = 24 * 60 * 60
    private let lastSnapshotKey = "wall.cloud.last-daily-snapshot.v1"
    private let bootstrapRestoreKey = "wall.cloud.bootstrap-restore.rich-layout.v1"
    private let photoEditsRestoreKey = "wall.cloud.photo-edits-restored.v1"
    private let photoEditsLastSnapshotKey = "wall.cloud.photo-edits-last-snapshot.v1"
    private var lastState: [String: Any] = [
        "schema": 1,
        "wall": [String: Any](),
        "photoBooth": [String: Any](),
    ]

    func configure(
        gifs: WallGIFStore,
        photoBoothGIFs: WallGIFStore,
        ink: InkCanvasModel,
        elements: WallElementStore,
        photoBoothElements: WallElementStore,
        widgets: WallWidgetStore,
        layers: WallLayerStore,
        photoBoothLayers: WallLayerStore
    ) {
        guard self.gifs == nil else { return }
        self.gifs = gifs
        self.photoBoothGIFs = photoBoothGIFs
        self.ink = ink
        self.elements = elements
        self.photoBoothElements = photoBoothElements
        self.widgets = widgets
        self.layers = layers
        self.photoBoothLayers = photoBoothLayers
        revision = defaults.integer(forKey: "wall.cloud.revision.v1")

        [
            gifs.objectWillChange.eraseToAnyPublisher(),
            photoBoothGIFs.objectWillChange.eraseToAnyPublisher(),
            ink.objectWillChange.eraseToAnyPublisher(),
            elements.objectWillChange.eraseToAnyPublisher(),
            photoBoothElements.objectWillChange.eraseToAnyPublisher(),
            widgets.objectWillChange.eraseToAnyPublisher(),
            layers.objectWillChange.eraseToAnyPublisher(),
            photoBoothLayers.objectWillChange.eraseToAnyPublisher(),
        ].forEach { publisher in
            publisher
                .sink { [weak self] _ in self?.schedulePush() }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.schedulePush() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: WallPhotoEditStorage.didChangeNotification)
            .sink { [weak self] _ in
                self?.photoEditsDirty = true
                self?.status = "local · photo edit backup pending"
            }
            .store(in: &cancellables)
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            if !self.defaults.bool(forKey: self.bootstrapRestoreKey) {
                await self.restoreCanonicalCanvasIfNeeded()
            } else {
                self.isReady = true
                self.isDirty = true
            }
            await self.restorePhotoEditsIfNeeded()
            await self.snapshotIfDue()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                if !self.defaults.bool(forKey: self.bootstrapRestoreKey) {
                    await self.restoreCanonicalCanvasIfNeeded()
                } else {
                    self.isReady = true
                }
                await self.restorePhotoEditsIfNeeded()
                await self.snapshotIfDue()
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func schedulePush() {
        guard !isApplying, isReady else { return }
        isDirty = true
        status = "local · daily backup pending"
    }

    private func snapshotIfDue() async {
        let lastSnapshot = defaults.double(forKey: lastSnapshotKey)
        if Date().timeIntervalSince1970 - lastSnapshot >= snapshotInterval {
            await push()
        } else {
            status = "local · backed up daily"
        }
        let lastPhotoSnapshot = defaults.double(forKey: photoEditsLastSnapshotKey)
        if Date().timeIntervalSince1970 - lastPhotoSnapshot >= snapshotInterval {
            await pushPhotoEditsIfDue()
        }
    }

    /// A missing app container must never be allowed to replace a richer Wall in Joan.
    /// Restore once on a fresh/repaired install, then return to local-first daily backups.
    private func restoreCanonicalCanvasIfNeeded() async {
        guard !isApplying else { return }
        status = "restoring layout"
        do {
            let request = authorizedRequest(path: "api/canvas")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 401 || http.statusCode == 403 {
                status = "waiting for device approval"
                return
            }
            guard http.statusCode == 200,
                  let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remoteRevision = document["revision"] as? Int,
                  remoteRevision > 0,
                  let state = document["state"] as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            try await apply(state: state, revision: remoteRevision)
            defaults.set(true, forKey: bootstrapRestoreKey)
            defaults.set(Date().timeIntervalSince1970, forKey: lastSnapshotKey)
            isReady = true
            isDirty = false
            status = "local · layout restored"
        } catch {
            // Keep retrying without uploading local fallback state over the canonical Wall.
            isReady = false
            isDirty = false
            status = "layout restore waiting"
        }
    }

    private func authorizedRequest(path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(KeychainToken.getOrCreate())", forHTTPHeaderField: "Authorization")
        request.setValue("Wall iPad", forHTTPHeaderField: "X-Wall-Device")
        return request
    }

    private func pull(quiet: Bool = false) async {
        guard !isDirty, !isApplying else { return }
        do {
            let request = authorizedRequest(path: "api/canvas")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 401 {
                if !quiet { status = "waiting for device approval" }
                return
            }
            guard http.statusCode == 200,
                  let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remoteRevision = document["revision"] as? Int,
                  let state = document["state"] as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            if remoteRevision == 0 {
                revision = 0
                lastState = state
                isReady = true
                isDirty = true
                await push()
                return
            }
            guard remoteRevision > revision else {
                isReady = true
                if !quiet { status = "saved" }
                return
            }
            try await apply(state: state, revision: remoteRevision)
            isReady = true
            status = "saved"
        } catch {
            if !quiet { status = "offline — saved locally" }
        }
    }

    private func apply(state: [String: Any], revision remoteRevision: Int) async throws {
        guard let gifs, let photoBoothGIFs, let ink, let elements,
              let photoBoothElements, let widgets, let layers, let photoBoothLayers,
              let wall = state["wall"] as? [String: Any],
              let booth = state["photoBooth"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let wallRecords: [WallCloudGIFRecord] = try decode(wall["gifs"] ?? [])
        let boothRecords: [WallCloudGIFRecord] = try decode(booth["gifs"] ?? [])
        var assets: [String: Data] = [:]
        for pair in gifs.cloudRecords() + photoBoothGIFs.cloudRecords() {
            assets[pair.record.asset] = pair.data
        }
        for asset in Set((wallRecords + boothRecords).map(\.asset)) where assets[asset] == nil {
            var request = authorizedRequest(path: "canvas-assets/\(asset).gif")
            request.timeoutInterval = 45
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            assets[asset] = data
        }

        isApplying = true
        defer { isApplying = false }
        gifs.applyCloudRecords(wallRecords, assets: assets)
        photoBoothGIFs.applyCloudRecords(boothRecords, assets: assets)
        if let value = wall["drawings"] { ink.applyCloudSnapshotData(try data(value)) }
        if let value = wall["elements"] { elements.applyCloudSnapshotData(try data(value)) }
        if let value = booth["elements"] { photoBoothElements.applyCloudSnapshotData(try data(value)) }
        if let value = wall["widgets"] { widgets.applyCloudSnapshotData(try data(value)) }
        if let value = wall["layers"] as? [String] { layers.applyCloudStorageKeys(value) }
        if let value = booth["layers"] as? [String] { photoBoothLayers.applyCloudStorageKeys(value) }
        if let note = wall["note"] as? [String: Any] {
            defaults.set(note["text"] as? String ?? "", forKey: "wall.note")
            defaults.set(note["font"] as? String ?? "Helvetica", forKey: "wall.note.font")
            defaults.set(note["size"] as? Double ?? 28, forKey: "wall.note.size")
        }
        let uploaded = Set(assets.keys)
        defaults.set(Array(uploaded).sorted(), forKey: "wall.cloud.uploaded-assets.v1")
        defaults.set(remoteRevision, forKey: "wall.cloud.revision.v1")
        revision = remoteRevision
        lastState = state
        isDirty = false
    }

    private func push() async {
        guard isDirty, !isApplying,
              let gifs, let photoBoothGIFs, let ink, let elements,
              let photoBoothElements, let widgets, let layers, let photoBoothLayers else { return }
        do {
            let wallPairs = gifs.cloudRecords()
            let boothPairs = photoBoothGIFs.cloudRecords()
            var uploaded = Set(defaults.stringArray(forKey: "wall.cloud.uploaded-assets.v1") ?? [])
            for pair in wallPairs + boothPairs where !uploaded.contains(pair.record.asset) {
                try await upload(asset: pair.record.asset, data: pair.data)
                uploaded.insert(pair.record.asset)
            }
            defaults.set(Array(uploaded).sorted(), forKey: "wall.cloud.uploaded-assets.v1")

            var state = lastState
            state["schema"] = 1
            var wall = state["wall"] as? [String: Any] ?? [:]
            var booth = state["photoBooth"] as? [String: Any] ?? [:]
            wall["gifs"] = try object(JSONEncoder().encode(wallPairs.map(\.record)))
            booth["gifs"] = try object(JSONEncoder().encode(boothPairs.map(\.record)))
            if let value = ink.cloudSnapshotData() { wall["drawings"] = try object(value) }
            if let value = elements.cloudSnapshotData() { wall["elements"] = try object(value) }
            if let value = photoBoothElements.cloudSnapshotData() { booth["elements"] = try object(value) }
            if let value = widgets.cloudSnapshotData() { wall["widgets"] = try object(value) }
            wall["layers"] = layers.cloudStorageKeys()
            booth["layers"] = photoBoothLayers.cloudStorageKeys()
            wall["note"] = [
                "text": defaults.string(forKey: "wall.note") ?? "",
                "font": defaults.string(forKey: "wall.note.font") ?? "Helvetica",
                "size": defaults.object(forKey: "wall.note.size") as? Double ?? 28,
            ]
            state["wall"] = wall
            state["photoBooth"] = booth
            state.removeValue(forKey: "photoEdits")

            var request = authorizedRequest(path: "api/device/canvas-snapshot", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "state": state,
            ])
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 401 || http.statusCode == 403 {
                status = "waiting for device approval"
                return
            }
            guard http.statusCode == 201,
                  let document = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let savedRevision = document["revision"] as? Int else {
                throw URLError(.badServerResponse)
            }
            revision = savedRevision
            lastState = state
            defaults.set(savedRevision, forKey: "wall.cloud.revision.v1")
            defaults.set(Date().timeIntervalSince1970, forKey: lastSnapshotKey)
            isDirty = false
            status = "local · backed up daily"
        } catch {
            status = "local · daily backup waiting"
        }
    }

    private func restorePhotoEditsIfNeeded() async {
        guard !defaults.bool(forKey: photoEditsRestoreKey) else { return }
        do {
            try await restorePhotoEdits()
            defaults.set(true, forKey: photoEditsRestoreKey)
            defaults.set(Date().timeIntervalSince1970, forKey: photoEditsLastSnapshotKey)
            photoEditsDirty = false
        } catch {
            status = "local · photo edit restore waiting"
        }
    }

    private func pushPhotoEditsIfDue() async {
        do {
            try await pushPhotoEdits()
            defaults.set(Date().timeIntervalSince1970, forKey: photoEditsLastSnapshotKey)
            photoEditsDirty = false
            status = "local · backed up daily"
        } catch {
            status = "local · main wall backed up · photo edits waiting"
        }
    }

    private func restorePhotoEdits() async throws {
        let (indexData, indexResponse) = try await URLSession.shared.data(
            for: authorizedRequest(path: "api/device/photo-edits")
        )
        guard (indexResponse as? HTTPURLResponse)?.statusCode == 200,
              let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let entries = index["edits"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }

        var records: [[String: Any]] = []
        var gifRecords: [WallCloudGIFRecord] = []
        for entry in entries.prefix(500) {
            guard let identifier = entry["id"] as? String,
                  identifier.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw URLError(.cannotParseResponse)
            }
            let (recordData, response) = try await URLSession.shared.data(
                for: authorizedRequest(path: "api/device/photo-edits/\(identifier)")
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let record = try JSONSerialization.jsonObject(with: recordData) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            records.append(record)
            if let value = record["gifs"] {
                let decoded: [WallCloudGIFRecord] = try decode(value)
                gifRecords.append(contentsOf: decoded)
            }
        }

        var assets: [String: Data] = [:]
        for asset in Set(gifRecords.map(\.asset)) {
            let (assetData, response) = try await URLSession.shared.data(
                for: authorizedRequest(path: "canvas-assets/\(asset).gif")
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            assets[asset] = assetData
        }
        await Task.detached(priority: .utility) {
            WallPhotoEditStorage.applyCloudSnapshot(records, assets: assets)
        }.value
    }

    private func pushPhotoEdits() async throws {
        let photoEdits = await Task.detached(priority: .utility) {
            WallPhotoEditStorage.cloudSnapshot()
        }.value
        var uploaded = Set(defaults.stringArray(forKey: "wall.cloud.uploaded-assets.v1") ?? [])
        for pair in photoEdits.assets where !uploaded.contains(pair.record.asset) {
            try await upload(asset: pair.record.asset, data: pair.data)
            uploaded.insert(pair.record.asset)
        }
        defaults.set(Array(uploaded).sorted(), forKey: "wall.cloud.uploaded-assets.v1")

        for record in photoEdits.records {
            guard let identifier = record["id"] as? String,
                  identifier.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { continue }
            var request = authorizedRequest(path: "api/device/photo-edits/\(identifier)", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: record)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201 else {
                throw URLError(.badServerResponse)
            }
        }
    }

    private func upload(asset: String, data: Data) async throws {
        var request = authorizedRequest(path: "api/canvas/assets", method: "POST")
        request.timeoutInterval = 60
        request.setValue("image/gif", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201,
              let payload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              payload["asset"] as? String == asset else {
            throw URLError(.badServerResponse)
        }
    }

    private func decode<T: Decodable>(_ value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: data(value))
    }

    private func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func object(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }
}
