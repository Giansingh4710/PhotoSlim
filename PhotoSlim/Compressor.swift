import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum Compressor {

    // MARK: - Preview

    /// Ask Photos for a bounded preview; do not load an entire original into memory
    /// just to display a small image. Photos applies orientation. iCloud is allowed.
    static func previewImage(for asset: PHAsset, maxPixel: Int) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit, options: options
            ) { image, info in
                guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                continuation.resume(returning: image)
            }
        }
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
        try Task.checkCancellation()
        let (url, compressedSize, originalSize) = try await compressToTemp(
            asset: asset, preset: preset, listedSize: listedSize, onProgress: onProgress
        )
        if Task.isCancelled { try? FileManager.default.removeItem(at: url); throw CancellationError() }
        return CompressedResult(
            original: asset,
            originalSize: originalSize,
            compressedURL: url,
            compressedSize: compressedSize
        )
    }

    struct BulkOutcome {
        var savedCount = 0
        var savedBytes: Int64 = 0
        var failures = 0          // items whose compression failed (skipped)
        var deletedIDs = Set<String>()
        var cancelled = false     // user declined a batch's delete prompt; the run stopped
        var errored = false       // a batch commit failed for a real reason; the run stopped
    }

    /// Bound both prompt count and temporary storage. One unusually large item gets
    /// its own batch and still has to pass the per-item free-space check.
    private static let batchSize = 100
    private static let batchByteBudget: Int64 = 256 * 1_024 * 1_024

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

        var start = 0
        while start < targets.count {
            var end = start
            var bytes: Int64 = 0
            while end < targets.count, end - start < batchSize {
                let next = max(0, targets[end].listedSize)
                if end > start, next > batchByteBudget - bytes { break }
                bytes += next
                end += 1
                if bytes >= batchByteBudget { break }
            }
            let batch = targets[start..<end]
            start = end

            // Compress the batch to temp files (nothing saved yet).
            var encoded: [(asset: PHAsset, url: URL, savedBytes: Int64)] = []
            for item in batch {
                if Task.isCancelled {
                    for item in encoded { try? FileManager.default.removeItem(at: item.url) }
                    outcome.cancelled = true
                    return outcome
                }
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
        } catch is CancellationError {
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
        try Task.checkCancellation()
        guard items.allSatisfy({ MediaSafety.unchanged($0.source) && FileManager.default.fileExists(atPath: $0.url.path) })
        else { throw CompressError.sourceChanged }
        var copyBytes: Int64 = 0
        for item in items {
            let size = try item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let (sum, overflow) = copyBytes.addingReportingOverflow(Int64(size))
            guard size > 0, !overflow else { throw CompressError.lowSpace }
            copyBytes = sum
        }
        guard StorageSafety.hasHeadroom(free: availableBytes(), bytes: copyBytes, copies: 1)
        else { throw CompressError.lowSpace }
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
    ///
    /// Regular albums only. Shared albums (.albumCloudShared) share the .album collection
    /// type, so they come back from this fetch — but an app can't add assets to them, and
    /// enqueueing that just makes Photos silently drop the request. Skip them explicitly
    /// rather than walking their contents for nothing. Shared-album membership is one of
    /// the things a replaced asset genuinely loses; see the Slim All confirm screen.
    static func userAlbumIndex(for assets: [PHAsset]) -> [String: [PHAssetCollection]] {
        let targetIDs = Set(assets.map(\.localIdentifier))
        guard !targetIDs.isEmpty else { return [:] }
        var index: [String: [PHAssetCollection]] = [:]
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { album, _, _ in
            guard album.assetCollectionType == .album,
                  album.assetCollectionSubtype != .albumCloudShared else { return }
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
    /// Originals are local-only by default. Previews may separately retrieve iCloud
    /// media, but compression never silently downloads an evicted original.
    static func compressToTemp(
        asset: PHAsset, preset: QualityPreset, listedSize: Int64,
        allowNetwork: Bool = false,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> (url: URL, compressedSize: Int64, originalSize: Int64) {
        try Task.checkCancellation()
        guard MediaSafety.resource(for: asset) != nil else { throw CompressError.unsafeMedia }
        guard MediaSafety.unchanged(asset) else { throw CompressError.sourceChanged }
        guard StorageSafety.hasHeadroom(free: availableBytes(), bytes: listedSize) else { throw CompressError.lowSpace }
        if asset.mediaType == .video {
            return try await VideoCompressor.exportToTemp(
                asset: asset, preset: preset, listedSize: listedSize,
                allowNetwork: allowNetwork, onProgress: onProgress
            )
        }
        // Bound compressed input buffering as well as the decoded pixel dimensions.
        guard listedSize <= 128 * 1_024 * 1_024 else { throw CompressError.unsafeMedia }
        let data = try await originalData(for: asset, allowNetwork: allowNetwork)
        try Task.checkCancellation()
        let encoded = try PhotoEncoder.encodeSmallest(data, preset: preset)
        try Task.checkCancellation()
        let url = try writeTemp(encoded.data)
        return (url, encoded.size, Int64(data.count))
    }

    /// Fresh unique temp-file URL with the given extension.
    static func tempURL(ext: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoSlimMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    /// Only our own scratch files; saved assets and recovery records are elsewhere.
    static func cleanAbandonedTemps() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoSlimMedia", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes HEIC bytes to a fresh unique temp file and returns its URL.
    private static func writeTemp(_ data: NSData) throws -> URL {
        let url = tempURL(ext: "heic")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func originalData(for asset: PHAsset, allowNetwork: Bool = true) async throws -> Data {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = allowNetwork
        options.isSynchronous = false

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else if info?[PHImageResultIsInCloudKey] as? Bool == true {
                    // Only reachable with allowNetwork == false — the caller asked to
                    // stay on-device, so this is a skip, not a failure.
                    continuation.resume(throwing: CompressError.notOnDevice)
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
        request.isHidden = source.isHidden

        for album in albums {
            PHAssetCollectionChangeRequest(for: album)?
                .addAssets([placeholder] as NSArray)
        }
        return placeholder.localIdentifier
    }

    // MARK: - Slim All primitives

    /// Creates ONE copy in its own creation-only transaction.
    ///
    /// Two properties the batched path (`performCreateDelete`) can't give us, both
    /// required by Slim All:
    ///   • creation-only changes never prompt, so a whole-library run stays silent
    ///     except for the periodic delete flushes;
    ///   • one asset per transaction gets its own distinct "date added", which is the
    ///     only lever iOS gives us over Recently Added ordering (addedDate is readonly).
    /// Batching creates would collide on that timestamp and scramble the order — which
    /// is the entire bug this feature exists to fix.
    ///
    /// Uses PHAssetCreationRequest (not the creationRequestForAssetFrom* convenience the
    /// per-tab flows use) for byte-exact resource control plus `originalFilename`, and
    /// `shouldMoveFile` so Photos can consume the temp rather than retain a second
    /// scratch copy. Capacity is still checked conservatively before importing.
    static func createOne(
        source: PHAsset,
        url: URL,
        filename: String?,
        albums: [PHAssetCollection]
    ) async throws -> String {
        try Task.checkCancellation()
        guard MediaSafety.unchanged(source) else { throw CompressError.sourceChanged }
        let fileBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard StorageSafety.hasHeadroom(free: availableBytes(), bytes: Int64(fileBytes), copies: 1)
        else { throw CompressError.lowSpace }
        var newID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()

            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            if let filename { options.originalFilename = filename }
            request.addResource(
                with: source.mediaType == .video ? .video : .photo,
                fileURL: url,
                options: options
            )

            // Same metadata carry-over as addCreation: Photos sorts the timeline on the
            // asset's own creationDate, so without this the copy lands at "today".
            request.creationDate = source.creationDate
            request.location = source.location
            request.isFavorite = source.isFavorite
            request.isHidden = source.isHidden

            guard let placeholder = request.placeholderForCreatedAsset else { return }
            newID = placeholder.localIdentifier
            for album in albums {
                PHAssetCollectionChangeRequest(for: album)?
                    .addAssets([placeholder] as NSArray)
            }
        }
        // addResource always "succeeds"; validation is deferred to the commit, so a nil
        // id here means the transaction really did produce nothing.
        guard let newID else { throw CompressError.encodeFailed }
        return newID
    }

    enum DeleteResult {
        case deleted(Set<String>)  // ALL requested ids confirmed gone
        case partial(Set<String>)  // some gone, some remain — the delete did not fully land
        case cancelled             // user declined the prompt — nothing changed
        case unknown               // nothing changed and no verdict; caller must re-verify
    }

    /// Deletes originals by id in ONE transaction, so iOS prompts once per flush.
    ///
    /// Await the actual PhotoKit result. Cancelling or timing out a Swift task cannot
    /// cancel an outstanding Photos confirmation; starting another delete would race it.
    static func deleteMany(_ ids: [String]) async -> DeleteResult {
        await deleteManyRace(ids)
    }

    private static func deleteManyRace(_ ids: [String]) async -> DeleteResult {
        guard !ids.isEmpty else { return .deleted([]) }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return .unknown }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        // Missing may mean revoked access, not deletion. Never infer a successful delete.
        guard assets.count == Set(ids).count else { return .unknown }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return .deleted(Set(ids))
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return .cancelled
        } catch { return .unknown }
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
        guard created.count == items.count else { throw CompressError.encodeFailed }
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
        // Simulator stress hook: inert unless launched with -slimFakeFreeMB.
        if let fake = DebugKnobs.fakeFreeMB {
            let (bytes, overflow) = Int64(fake).multipliedReportingOverflow(by: 1_024 * 1_024)
            return overflow ? nil : max(0, bytes)
        }
        let url = FileManager.default.temporaryDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
