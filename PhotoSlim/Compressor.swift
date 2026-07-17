import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum Compressor {

    /// Decodes image bytes to a UIImage no larger than `maxPixel` on its long edge,
    /// downscaling during decode (ImageIO) rather than loading the full bitmap. Used for
    /// the compare preview so a 48MP photo doesn't become a full-res UIImage in memory.
    static func thumbnail(from data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    static func thumbnail(fromFile url: URL, maxPixel: Int) -> UIImage? {
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

        // Some already-compressed sources don't shrink at the chosen quality (a HEIC
        // re-encode at 0.8 can even grow). Step the quality down until the output is
        // genuinely smaller, so "High" still yields a real saving instead of an error.
        let originalSize = Int64(data.count)
        let qualities = [preset.quality, 0.6, 0.4, 0.3].filter { $0 <= preset.quality }

        var smallest: (data: NSData, size: Int64, quality: Double)?
        for quality in qualities {
            guard let encoded = encodeHEIC(source, quality: quality) else { continue }
            let size = Int64(encoded.length)
            if size < (smallest?.size ?? .max) {
                smallest = (encoded, size, quality)
            }
            if size < originalSize { break }  // good enough — stop stepping down
        }

        guard let smallest, smallest.size < originalSize else {
            // Even the lowest quality couldn't beat the original — truly incompressible.
            throw CompressError.noGain(decoded: originalSize, compressed: smallest?.size ?? originalSize)
        }

        let url = try writeTemp(smallest.data)
        return CompressedResult(
            original: asset,
            originalData: data,
            originalSize: max(listedSize, Int64(data.count)),
            compressedURL: url,
            compressedSize: smallest.size,
            quality: smallest.quality
        )
    }

    /// Re-encodes already-loaded original bytes at a specific quality and writes a fresh
    /// temp file. Used by the compare view's live quality slider — no PHAsset round-trip.
    /// Returns nil if decode/encode fails. Does NOT enforce a size reduction: the slider
    /// shows the honest result even when a high quality grows the file.
    static func reencode(originalData: Data, quality: Double) -> (url: URL, size: Int64)? {
        guard let source = CGImageSourceCreateWithData(originalData as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let encoded = encodeHEIC(source, quality: quality),
              let url = try? writeTemp(encoded) else { return nil }
        return (url, Int64(encoded.length))
    }

    /// Writes HEIC bytes to a fresh unique temp file and returns its URL.
    private static func writeTemp(_ data: NSData) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")
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
