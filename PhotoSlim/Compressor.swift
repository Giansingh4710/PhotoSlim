import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers

enum Compressor {

    // MARK: - Compress

    /// Re-encodes the asset as HEIC at the preset's quality, preserving all metadata.
    /// Resolution is untouched — only the encoder's lossy quality changes.
    /// `listedSize` is the on-disk file size shown in the list (PHAssetResource.fileSize).
    /// It's the number the user saw, so the compare view reports savings against it —
    /// requestImageDataAndOrientation can return different bytes for edited assets.
    static func compress(_ asset: PHAsset, preset: QualityPreset, listedSize: Int64) async throws -> CompressedResult {
        let data = try await originalData(for: asset)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw CompressError.decodeFailed
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.heic.identifier as CFString, 1, nil
        ) else {
            throw CompressError.encodeFailed
        }

        // AddImageFromSource carries EXIF/GPS/TIFF/orientation across verbatim.
        // The options dict only layers the compression quality on top.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: preset.quality]
        CGImageDestinationAddImageFromSource(dest, source, 0, options as CFDictionary)

        guard CGImageDestinationFinalize(dest) else { throw CompressError.encodeFailed }

        let compressedSize = Int64(out.length)
        // Compare gain against the actual decoded bytes; if the encode didn't shrink
        // those, it won't shrink the file either.
        guard compressedSize < Int64(data.count) else { throw CompressError.noGain }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")
        try out.write(to: url, options: .atomic)

        return CompressedResult(
            original: asset,
            originalData: data,
            originalSize: max(listedSize, Int64(data.count)),
            compressedURL: url,
            compressedSize: compressedSize
        )
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

    /// Saves the compressed file as a new asset carrying the original's date,
    /// location, favorite flag and user-album membership.
    @discardableResult
    static func save(_ result: CompressedResult) async throws -> String {
        let source = result.original
        let albums = userAlbums(containing: source)
        var newID: String?

        try await PHPhotoLibrary.shared().performChanges {
            // Both must exist before we touch anything — otherwise nothing is enqueued
            // and the block commits a no-op rather than a half-configured orphan asset.
            guard let request = PHAssetChangeRequest.creationRequestForAssetFromImage(
                atFileURL: result.compressedURL
            ), let placeholder = request.placeholderForCreatedAsset else { return }

            // The file's EXIF already holds date/GPS, but Photos sorts on the asset's
            // own creationDate — without this the copy lands at "today".
            request.creationDate = source.creationDate
            request.location = source.location
            request.isFavorite = source.isFavorite
            newID = placeholder.localIdentifier

            for album in albums {
                PHAssetCollectionChangeRequest(for: album)?
                    .addAssets([placeholder] as NSArray)
            }
        }

        guard let newID else { throw CompressError.saveFailed }
        return newID
    }

    /// Only user-created albums — smart albums reject inserts.
    private static func userAlbums(containing asset: PHAsset) -> [PHAssetCollection] {
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(
            asset, with: .album, options: nil
        )
        var result: [PHAssetCollection] = []
        collections.enumerateObjects { collection, _, _ in
            if collection.assetCollectionType == .album {
                result.append(collection)
            }
        }
        return result
    }

    // MARK: - Delete

    /// One performChanges block => a single system confirmation for the whole batch.
    /// If the user cancels, this throws and the compressed copies remain.
    static func deleteOriginals(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    static func discard(_ results: [CompressedResult]) {
        for result in results {
            try? FileManager.default.removeItem(at: result.compressedURL)
        }
    }
}
