import Foundation
import Photos
import AVFoundation

@Observable
@MainActor
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {

    let mediaType: PHAssetMediaType
    let minThreshold: Int64
    let maxThreshold: Int64

    var threshold: Int64

    var items: [PhotoItem] = []
    private(set) var sortOrder: SortOrder = .size
    var scanProgress: Double = 0
    var isScanning = false
    var authStatus: PHAuthorizationStatus = .notDetermined

    private let sizeCache: SizeCache
    private var isObservingLibrary = false

    init(mediaType: PHAssetMediaType = .image) {
        self.mediaType = mediaType
        if mediaType == .video {
            minThreshold = 5 * 1_024 * 1_024               // 5 MB
            maxThreshold = 2 * 1_024 * 1_024 * 1_024       // 2 GB
            threshold = 50 * 1_024 * 1_024                 // 50 MB
            sizeCache = SizeCache(filename: "video-sizes.plist")
        } else {
            minThreshold = 500 * 1_024                     // 500 KB
            maxThreshold = 50 * 1_024 * 1_024              // 50 MB
            threshold = 5 * 1_024 * 1_024                  // 5 MB
            sizeCache = SizeCache(filename: "photo-sizes.plist")
        }
        super.init()
        // Restore the saved sort for this media type (photos and videos remember
        // their own choice).
        if let raw = UserDefaults.standard.string(forKey: sortDefaultsKey),
           let saved = SortOrder(rawValue: raw) {
            sortOrder = saved
        }
        // A Slim All run suppresses (discards) change-driven rescans app-wide; this is
        // the "run ended, reconcile once" signal that replaces them.
        NotificationCenter.default.addObserver(
            self, selector: #selector(slimRunEnded), name: .slimRunEnded, object: nil
        )
    }

    @objc private nonisolated func slimRunEnded() {
        Task { @MainActor in
            guard self.hasScanned else { return }  // never-scanned tabs scan on first appear
            await self.rescan(silent: true)
        }
    }

    private var sortDefaultsKey: String {
        "sortOrder-\(mediaType == .video ? "video" : "photo")"
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    /// Library changed (Photos-app edits, iCloud sync, our own saves/deletes) →
    /// debounced rescan so the list never goes stale. The debounce also coalesces
    /// external change bursts.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.scheduleRescan() }
    }

    private var rescanTask: Task<Void, Never>?
    private var observingPaused = false

    /// Set for the duration of a Slim All run. That run creates and deletes thousands of
    /// assets; without this, both list tabs would each schedule a rescan storm that fights
    /// the compression loop for the whole run. Static because the run doesn't own — and
    /// shouldn't have to find — the other tabs' library instances.
    nonisolated(unsafe) static var suppressRescans = false

    /// Silence change-driven rescans during a bulk run — its own chunk commits would
    /// otherwise trigger dozens of full scans that fight the compression loop and
    /// re-list the copies it just made. resumeObserving() does exactly ONE reconciling
    /// scan at the end (the run created copies that may or may not clear the threshold),
    /// replacing the mid-run storm. That final scan is silent — the caller already
    /// pruned deleted rows via remove(ids:), so it shouldn't flash the "Scanning…" view.
    func pauseObserving() { observingPaused = true; rescanTask?.cancel() }
    func resumeObserving() {
        observingPaused = false
        Task { await rescan(silent: true) }
    }

    private func scheduleRescan() {
        guard hasScanned, !observingPaused, !Self.suppressRescans else { return }
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await rescan()
        }
    }

    /// Run a scan, and if one is already in flight, queue exactly one follow-up so the
    /// caller's intent (e.g. a new threshold) is never silently dropped. `silent`
    /// suppresses the "Scanning…" UI (used for post-bulk reconciliation, where the list
    /// is already mostly correct and a full-screen scan view would just flicker).
    func rescan(silent: Bool = false) async {
        guard !Self.suppressRescans else { return }
        if isRunningScan { rescanPending = true; return }
        await scan(silent: silent)
        while rescanPending {
            rescanPending = false
            await scan(silent: silent)
        }
    }

    private var rescanPending = false
    private var isRunningScan = false

    var totalSize: Int64 { items.reduce(0) { $0 + $1.byteSize } }

    // MARK: - Auth

    func requestAccess() async {
        let previous = authStatus
        authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if previous != authStatus { hasScanned = false; items = [] }
        if (authStatus == .authorized || authStatus == .limited), !isObservingLibrary {
            PHPhotoLibrary.shared().register(self)
            isObservingLibrary = true
        }
        // The view's .task re-fires on every tab switch — only auto-scan once.
        // Rescans still happen explicitly via the threshold slider.
        if (authStatus == .authorized || authStatus == .limited) && !hasScanned {
            await scan()
        }
    }

    // MARK: - Scan

    private var hasScanned = false

    func scan(silent: Bool = false) async {
        guard !isRunningScan else { return }
        authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authStatus == .authorized || authStatus == .limited else { items = []; hasScanned = false; return }
        isRunningScan = true
        hasScanned = true
        // isScanning drives the "Scanning…" view; a silent reconciling scan leaves it
        // false so the list stays visible and just updates in place.
        if !silent { isScanning = true; scanProgress = 0 }
        defer { isRunningScan = false; isScanning = false }

        let assets = fetchAssets()
        let cached = sizeCache.load()
        // Snapshot the threshold once so a slider change mid-scan can't filter early
        // items against one value and later items against another. rescan() runs a
        // fresh pass afterward if the value moved.
        let cutoff = threshold

        var scanned: [PhotoItem] = []
        var freshSizes: [String: Int64] = [:]
        let total = max(assets.count, 1)

        for (index, asset) in assets.enumerated() {
            guard !Task.isCancelled else { hasScanned = false; return }
            guard MediaSafety.resource(for: asset) != nil else { continue }
            let key = Self.cacheKey(asset)
            let size: Int64
            if let hit = cached[key] {
                size = hit
            } else {
                size = await Self.byteSize(of: asset)
                if size > 0 { freshSizes[key] = size }
            }

            if size >= cutoff {
                scanned.append(PhotoItem(asset: asset, byteSize: size))
            }

            scanProgress = Double(index + 1) / Double(total)
            if index % 50 == 0 { await Task.yield() }
        }

        items = Self.sorted(scanned, by: sortOrder)
        scanProgress = 1

        sizeCache.merge(cached, freshSizes, keeping: assets.map(Self.cacheKey))
    }

    func remove(ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        sizeCache.forget(ids)
    }

    /// Change the sort and re-order the current list in place — no rescan needed.
    /// The choice is persisted so it survives app restarts.
    func setSort(_ order: SortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        UserDefaults.standard.set(order.rawValue, forKey: sortDefaultsKey)
        items = Self.sorted(items, by: order)
    }

    private static func sorted(_ items: [PhotoItem], by order: SortOrder) -> [PhotoItem] {
        switch order {
        case .size:
            return items.sorted { $0.byteSize > $1.byteSize }  // byteSize is a stored let
        case .date:
            // Newest first; assets without a creationDate sort last. Read the bridged
            // PHAsset.creationDate once per item (decorate-sort-undecorate) instead of
            // ~2·log n times inside the comparator.
            return items
                .map { (item: $0, date: $0.asset.creationDate ?? .distantPast) }
                .sorted { $0.date > $1.date }
                .map(\.item)
        }
    }

    private func fetchAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if mediaType == .image {
            // Live Photos need still+video re-encode and pairing — out of scope.
            options.predicate = NSPredicate(
                format: "NOT ((mediaSubtypes & %d) != 0)", PHAssetMediaSubtype.photoLive.rawValue
            )
        }

        let result = PHAsset.fetchAssets(with: mediaType, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    nonisolated static func cacheKey(_ asset: PHAsset) -> String {
        asset.localIdentifier + "|" + String(asset.modificationDate?.timeIntervalSince1970 ?? 0)
    }

    nonisolated static func cachedSizes() -> [String: Int64] {
        var merged = SizeCache(filename: "photo-sizes.plist").load()
        merged.merge(SizeCache(filename: "video-sizes.plist").load()) { _, new in new }
        return merged
    }

    /// Read local file metadata through public editing-input URLs first. If Photos
    /// cannot expose a matching original URL, stream bytes without retaining media.
    /// Neither path downloads iCloud originals; unknown sizes are never cached.
    nonisolated static func byteSize(of asset: PHAsset) async -> Int64 {
        guard !Task.isCancelled, let resource = MediaSafety.resource(for: asset) else { return 0 }
        let inputOptions = PHContentEditingInputRequestOptions()
        inputOptions.isNetworkAccessAllowed = false
        let localSize: Int64 = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: inputOptions) { input, _ in
                guard let input, input.uniformTypeIdentifier == resource.uniformTypeIdentifier,
                      let url = input.fullSizeImageURL ?? (input.audiovisualAsset as? AVURLAsset)?.url,
                      url.isFileURL,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0 else { continuation.resume(returning: 0); return }
                continuation.resume(returning: Int64(size))
            }
        }
        if localSize > 0 { return localSize }
        guard !Task.isCancelled else { return 0 }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let counter = ResourceByteCounter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let request = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    counter.add(data.count)
                } completionHandler: { error in
                    continuation.resume(returning: error == nil ? counter.value : 0)
                }
                counter.register(request)
            }
        } onCancel: { counter.cancel() }
    }

}

extension Notification.Name {
    /// Posted when a Slim All run stops suppressing rescans — see PhotoLibrary.suppressRescans.
    static let slimRunEnded = Notification.Name("slimRunEnded")
}

// ponytail: plist dict, not Core Data. Revisit if libraries get big enough to stall launch.
private struct SizeCache {
    private let url: URL

    init(filename: String) {
        url = URL.cachesDirectory.appendingPathComponent(filename)
    }

    func load() -> [String: Int64] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListDecoder().decode([String: Int64].self, from: data)
        else { return [:] }
        return dict
    }

    /// Persist cached + fresh sizes, dropping entries for assets no longer in the library.
    func merge(_ cached: [String: Int64], _ fresh: [String: Int64], keeping ids: [String]) {
        let live = Set(ids)
        var merged = cached.filter { live.contains($0.key) }
        for (key, value) in fresh { merged[key] = value }
        write(merged)
    }

    func forget(_ ids: Set<String>) {
        var dict = load()
        dict = dict.filter { entry in !ids.contains(String(entry.key.split(separator: "|").first ?? "")) }
        write(dict)
    }

    private func write(_ dict: [String: Int64]) {
        guard let data = try? PropertyListEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private final class ResourceByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var request: PHAssetResourceDataRequestID?
    private var cancelled = false
    func register(_ request: PHAssetResourceDataRequestID) {
        lock.lock(); self.request = request; let cancelNow = cancelled; lock.unlock()
        if cancelNow { PHAssetResourceManager.default().cancelDataRequest(request) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let request = request; lock.unlock()
        if let request { PHAssetResourceManager.default().cancelDataRequest(request) }
    }
    func add(_ count: Int) { lock.lock(); defer { lock.unlock() }; bytes += Int64(count) }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
}
