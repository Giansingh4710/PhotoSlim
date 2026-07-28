import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum Compressor {

    // MARK: - Preview

    /// Full-quality preview image of the asset's current version, downscaled during
    /// decode to `maxPixel` on the long edge — a 48MP photo never becomes a full-res
    /// UIImage in memory. Honors EXIF orientation. iCloud download allowed.
    static func previewImage(for asset: PHAsset, maxPixel: Int) async -> UIImage? {
        guard let data = try? await originalData(for: asset),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    /// Preview image straight from a compressed temp file on disk.
    static func previewImage(fromFile url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Compress

    /// Compresses one asset (photo or video) to a temp file for review. Nothing is
    /// saved to the library until the review sheet decides. `onProgress` reports the
    /// video export fraction (photos finish too fast to report).
    static func compress(
        _ asset: PHAsset, preset: QualityPreset, listedSize: Int64,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> CompressedResult {
        let (url, compressedSize, originalSize) = try await compressToTemp(
            asset: asset, preset: preset, listedSize: listedSize, onProgress: onProgress
        )
        return CompressedResult(
            original: asset,
            originalSize: originalSize,
            compressedURL: url,
            compressedSize: compressedSize
        )
    }

    /// Some already-compressed sources don't shrink at the chosen quality (a HEIC
    /// re-encode at 0.8 can even grow). Steps the quality down until the output is
    /// genuinely smaller, so "High" still yields a real saving instead of an error.
    /// Runs inside an autoreleasepool so ImageIO temporaries drain per call instead
    /// of piling up across a bulk batch.
    private static func encodeSmallest(
        _ data: Data, preset: QualityPreset
    ) throws -> (data: NSData, size: Int64) {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else {
                throw CompressError.decodeFailed
            }

            let originalSize = Int64(data.count)
            let qualities = [preset.quality] + [0.6, 0.4, 0.3].filter { $0 < preset.quality }

            var smallest: (data: NSData, size: Int64)?
            for quality in qualities {
                guard let encoded = encodeHEIC(source, quality: quality) else { continue }
                let size = Int64(encoded.length)
                if size < (smallest?.size ?? .max) {
                    smallest = (encoded, size)
                }
                if size < originalSize { break }  // good enough — stop stepping down
            }

            guard let smallest, smallest.size < originalSize else {
                // Even the lowest quality couldn't beat the original — truly incompressible.
                throw CompressError.noGain(decoded: originalSize, compressed: smallest?.size ?? originalSize)
            }
            return smallest
        }
    }

    struct BulkOutcome {
        var savedCount = 0
        var savedBytes: Int64 = 0
        var failures = 0          // items whose compression failed (skipped)
        var deletedIDs = Set<String>()
        var cancelled = false     // user declined a batch's delete prompt; the run stopped
        var errored = false       // a batch commit failed for a real reason; the run stopped
    }

    /// Batches of 100. Each batch commits atomically (create copies + delete originals
    /// in ONE transaction), so iOS prompts once per batch and every confirmed batch is
    /// fully clean. Large batches keep the prompt count low; the trade-off is one prompt
    /// per 100 items (iOS has no way to pre-authorize deletions).
    private static let batchSize = 100

    /// Bulk pipeline for photos or videos, safe to interrupt. Each batch is compressed
    /// to temp files, then created-and-deleted in a single atomic transaction:
    ///   • confirmed batch  → copies saved AND originals deleted together (clean)
    ///   • declined batch   → nothing changes for that batch, and the run stops
    ///   • quit mid-run     → completed batches are clean, untouched items untouched
    /// There is never a window where copies exist without their originals removed, so an
    /// interrupted run can't leave the orphaned-duplicates mess a save-all-then-delete
    /// design would. Failed compressions are skipped (counted, not fatal).
    static func bulkCompressAndDelete(
        _ targets: [(asset: PHAsset, listedSize: Int64)],
        preset: QualityPreset,
        onProgress: @escaping @MainActor (_ itemsDone: Int) -> Void
    ) async -> BulkOutcome {
        var outcome = BulkOutcome()
        let albumIndex = userAlbumIndex(for: targets.map(\.asset))
        var done = 0

        for start in stride(from: 0, to: targets.count, by: batchSize) {
            let batch = targets[start..<min(start + batchSize, targets.count)]

            // Compress the batch to temp files (nothing saved yet).
            var encoded: [(asset: PHAsset, url: URL, savedBytes: Int64)] = []
            for item in batch {
                do {
                    let (url, compressedSize, originalSize) = try await compressToTemp(
                        asset: item.asset, preset: preset, listedSize: item.listedSize
                    )
                    encoded.append((item.asset, url, originalSize - compressedSize))
                } catch {
                    outcome.failures += 1  // skip and move on
                }
                done += 1
                await onProgress(done)
            }

            // Atomic commit: create copies + delete their originals in one transaction.
            let result = await commitBatch(encoded, albumIndex: albumIndex)
            // Temps are useless once the transaction has run (or been rolled back).
            for item in encoded { try? FileManager.default.removeItem(at: item.url) }

            switch result {
            case .committed(let deleted):
                for item in encoded where deleted.contains(item.asset.localIdentifier) {
                    outcome.savedBytes += item.savedBytes
                }
                outcome.savedCount += deleted.count
                outcome.deletedIDs.formUnion(deleted)
            case .cancelled:
                // Nothing changed for this batch; stop cleanly, rest untouched.
                outcome.cancelled = true
                return outcome
            case .failed:
                // Real error rolled the batch back; stop and surface it. The batch's
                // items are not "compression failures" — they're just not done.
                outcome.errored = true
                return outcome
            }
        }
        return outcome
    }

    enum BatchResult {
        case committed(Set<String>)  // deleted originals' localIdentifiers
        case cancelled               // user declined the delete prompt — nothing changed
        case failed                  // real error; nothing changed for this batch
    }

    /// Atomically creates the batch's copies AND deletes exactly those originals whose
    /// copy got enqueued, in ONE transaction — so iOS shows its delete confirmation once
    /// per batch. A decline or a real error rolls the whole transaction back (nothing
    /// changes); we never retry per item, which would fan out one delete prompt per file.
    private static func commitBatch(
        _ encoded: [(asset: PHAsset, url: URL, savedBytes: Int64)],
        albumIndex: [String: [PHAssetCollection]]
    ) async -> BatchResult {
        guard !encoded.isEmpty else { return .committed([]) }
        // Resolve each item's albums up front so the transaction closure captures only
        // this batch's memberships, not the whole-library album index.
        let items = encoded.map { ($0.asset, $0.url, albumIndex[$0.asset.localIdentifier] ?? []) }
        do {
            let created = try await performCreateDelete(items)
            return .committed(Set(created.map(\.localIdentifier)))
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return .cancelled
        } catch {
            return .failed
        }
    }

    /// The app's core transaction: in ONE performChanges, create each copy and (when
    /// `deleteOriginals`) delete only the originals whose copy actually got a placeholder.
    /// A nil creation (e.g. a purged temp file) is skipped so its original is never
    /// deleted without a copy. Returns the created sources. Shared by the bulk pipeline
    /// and the single-item review, so the "never orphan a copy" invariant lives once.
    /// Each item carries its own resolved album memberships — the block captures only
    /// `items`, not any library-wide index.
    private static func performCreateDelete(
        _ items: [(source: PHAsset, url: URL, albums: [PHAssetCollection])],
        deleteOriginals: Bool = true
    ) async throws -> [PHAsset] {
        var created: [PHAsset] = []
        try await PHPhotoLibrary.shared().performChanges {
            created = []
            for (source, url, albums) in items {
                if addCreation(source: source, url: url, albums: albums) != nil {
                    created.append(source)
                }
            }
            if deleteOriginals && !created.isEmpty {
                PHAssetChangeRequest.deleteAssets(created as NSArray)
            }
        }
        return created
    }

    /// One pass over the user albums each target belongs to → asset id → containing
    /// albums. Only indexes the targeted assets, so a huge library with big albums
    /// doesn't materialize hundreds of thousands of memberships for a small run.
    private static func userAlbumIndex(for assets: [PHAsset]) -> [String: [PHAssetCollection]] {
        let targetIDs = Set(assets.map(\.localIdentifier))
        guard !targetIDs.isEmpty else { return [:] }
        var index: [String: [PHAssetCollection]] = [:]
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { album, _, _ in
            guard album.assetCollectionType == .album else { return }
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                guard targetIDs.contains(asset.localIdentifier) else { return }
                index[asset.localIdentifier, default: []].append(album)
            }
        }
        return index
    }

    /// Compresses one asset (photo or video) to a temp file, dispatching on media type.
    /// Returns only small values so image buffers are released when this frame exits —
    /// before the caller awaits the library save.
    private static func compressToTemp(
        asset: PHAsset, preset: QualityPreset, listedSize: Int64,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> (url: URL, compressedSize: Int64, originalSize: Int64) {
        if asset.mediaType == .video {
            return try await VideoCompressor.exportToTemp(
                asset: asset, preset: preset, listedSize: listedSize, onProgress: onProgress
            )
        }
        let data = try await originalData(for: asset)
        let encoded = try encodeSmallest(data, preset: preset)
        let url = try writeTemp(encoded.data)
        return (url, encoded.size, max(listedSize, Int64(data.count)))
    }

    /// Fresh unique temp-file URL with the given extension.
    static func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    /// Writes HEIC bytes to a fresh unique temp file and returns its URL.
    private static func writeTemp(_ data: NSData) throws -> URL {
        let url = tempURL(ext: "heic")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Encodes the source image to HEIC at the given quality, preserving metadata.
    /// AddImageFromSource carries EXIF/GPS/TIFF/orientation across verbatim.
    private static func encodeHEIC(_ source: CGImageSource, quality: Double) -> NSData? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImageFromSource(dest, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out
    }

    private static func originalData(for asset: PHAsset) async throws -> Data {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CompressError.loadFailed)
                }
            }
        }
    }

    // MARK: - Save

    /// Enqueues one copy-creation. Must run inside a performChanges block.
    /// Returns the placeholder's localIdentifier, or nil if nothing was enqueued.
    @discardableResult
    private static func addCreation(source: PHAsset, url: URL, albums: [PHAssetCollection]) -> String? {
        // Both must exist before we touch anything — otherwise nothing is enqueued
        // and the block commits a no-op rather than a half-configured orphan asset.
        let request = source.mediaType == .video
            ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        guard let request, let placeholder = request.placeholderForCreatedAsset else { return nil }

        // The file's EXIF already holds date/GPS, but Photos sorts on the asset's
        // own creationDate — without this the copy lands at "today".
        request.creationDate = source.creationDate
        request.location = source.location
        request.isFavorite = source.isFavorite

        for album in albums {
            PHAssetCollectionChangeRequest(for: album)?
                .addAssets([placeholder] as NSArray)
        }
        return placeholder.localIdentifier
    }

    // MARK: - Review finish

    enum ReviewOutcome {
        case deleted    // copies saved, originals deleted
        case kept       // copies saved, originals kept by choice
        case cancelled  // user declined the delete prompt — nothing was changed
    }

    /// Shared tail of the review sheet. Nothing touches the library before this runs,
    /// and everything commits in ONE transaction (via performCreateDelete): Keep Both
    /// saves the copies; Delete Original saves the copy AND deletes the original
    /// atomically, so declining the system prompt leaves the library untouched.
    static func finishReview(
        _ results: [CompressedResult],
        deleteOriginals: Bool
    ) async throws -> ReviewOutcome {
        let albumIndex = userAlbumIndex(for: results.map(\.original))
        let items = results.map {
            ($0.original, $0.compressedURL, albumIndex[$0.original.localIdentifier] ?? [])
        }
        let created: [PHAsset]
        do {
            created = try await performCreateDelete(items, deleteOriginals: deleteOriginals)
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return .cancelled
        }
        // Nothing enqueued at all → the copies never saved; surface it as an error.
        guard !created.isEmpty else { throw CompressError.encodeFailed }
        return deleteOriginals ? .deleted : .kept
    }

    static func discard(_ results: [CompressedResult]) {
        for result in results {
            try? FileManager.default.removeItem(at: result.compressedURL)
        }
    }

    /// Free space on the volume backing the temp directory, or nil if unavailable.
    /// Bulk runs write a compressed copy per item before the original is deleted (and
    /// deleted originals sit in Recently Deleted for ~30 days), so a low-space device
    /// can run out mid-run — the caller warns the user when headroom is thin.
    static func availableBytes() -> Int64? {
        let url = FileManager.default.temporaryDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
