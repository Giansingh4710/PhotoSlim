import Foundation
import Photos

@Observable
@MainActor
final class PhotoLibrary {

    /// Photos below this aren't worth compressing.
    static let sizeThreshold: Int64 = 5 * 1_024 * 1_024

    var items: [PhotoItem] = []
    var scanProgress: Double = 0
    var isScanning = false
    var authStatus: PHAuthorizationStatus = .notDetermined

    private var sizeCache = SizeCache()

    var totalSize: Int64 { items.reduce(0) { $0 + $1.byteSize } }

    // MARK: - Auth

    func requestAccess() async {
        authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if authStatus == .authorized {
            await scan()
        }
    }

    // MARK: - Scan

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0
        defer { isScanning = false }

        let assets = fetchAssets()
        let cached = sizeCache.load()

        var scanned: [PhotoItem] = []
        var freshSizes: [String: Int64] = [:]
        let total = max(assets.count, 1)

        for (index, asset) in assets.enumerated() {
            let size: Int64
            if let hit = cached[asset.localIdentifier] {
                size = hit
            } else {
                size = await Self.byteSize(of: asset)
                freshSizes[asset.localIdentifier] = size
            }

            if size >= Self.sizeThreshold {
                scanned.append(PhotoItem(asset: asset, byteSize: size))
            }

            scanProgress = Double(index + 1) / Double(total)
            if index % 50 == 0 { await Task.yield() }
        }

        scanned.sort { $0.byteSize > $1.byteSize }
        items = scanned
        scanProgress = 1

        sizeCache.merge(cached, freshSizes, keeping: assets.map(\.localIdentifier))
    }

    func remove(ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        sizeCache.forget(ids)
    }

    private func fetchAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Live Photos need still+video re-encode and pairing — out of scope.
        options.predicate = NSPredicate(
            format: "NOT ((mediaSubtypes & %d) != 0)", PHAssetMediaSubtype.photoLive.rawValue
        )

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// PHAsset exposes no public byte size. The fileSize KVC key on PHAssetResource
    /// is the standard workaround and is App Store-accepted.
    /// ponytail: KVC key could break on a future iOS — returns 0, item sorts out of view.
    nonisolated static func byteSize(of asset: PHAsset) async -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .fullSizePhoto }
            ?? resources.first
        guard let resource else { return 0 }
        return (resource.value(forKey: "fileSize") as? Int64) ?? 0
    }
}

// ponytail: plist dict, not Core Data. Revisit if libraries get big enough to stall launch.
private struct SizeCache {
    private let url = URL.cachesDirectory.appendingPathComponent("photo-sizes.plist")

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
        for id in ids { dict.removeValue(forKey: id) }
        write(dict)
    }

    private func write(_ dict: [String: Int64]) {
        guard let data = try? PropertyListEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
