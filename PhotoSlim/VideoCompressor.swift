import Foundation
import Photos
import AVFoundation

enum VideoCompressor {

    /// Player item for the asset's current version — streams/downloads from Photos
    /// (iCloud allowed). Used by the review sheet to play the original.
    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard !resumed else { return }  // Photos may call back more than once
                resumed = true
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - Export

    /// Exports the asset to a temp file at the preset's resolution tier (HEVC/H.264 per
    /// the export preset), returning the same small tuple the photo path does so
    /// Compressor's pipeline stays media-agnostic. `onProgress` reports export fraction
    /// (bulk passes a no-op; the single-item flow drives a determinate bar). Throws
    /// .noGain when the export isn't smaller than the current rendition.
    static func exportToTemp(
        asset: PHAsset, preset: QualityPreset, listedSize: Int64,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> (url: URL, compressedSize: Int64, originalSize: Int64) {
        let session = try await exportSession(for: asset, preset: preset)

        let url = Compressor.tempURL(ext: "mov")
        session.outputURL = url
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true

        // ponytail: 0.5s progress polling — replace with the async `states` API
        // once the deployment target is iOS 18.
        // MainActor task: the cancel-check and callback run atomically on the main
        // actor, so no stale progress write can land after export() returns.
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                onProgress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poller.cancel() }

        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw CompressError.encodeFailed
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        // Judge the export against the *current* rendition, not the cached list
        // size — an edited video's cached size describes the untouched original,
        // which can dwarf (or trail) what the user actually has.
        let inputSize = currentSize(of: asset, fallback: listedSize)
        guard size > 0, size < inputSize else {
            try? FileManager.default.removeItem(at: url)
            throw CompressError.noGain(decoded: inputSize, compressed: size)
        }
        return (url: url, compressedSize: size, originalSize: inputSize)
    }

    /// Byte size of the video's current rendition: the edited .fullSizeVideo
    /// resource when one exists, else the original .video resource.
    private static func currentSize(of asset: PHAsset, fallback: Int64) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .fullSizeVideo }
            ?? resources.first { $0.type == .video }
        guard let size = resource?.value(forKey: "fileSize") as? Int64, size > 0 else {
            return fallback  // ponytail: KVC key gone on a future iOS → old behavior
        }
        return size
    }

    /// One call handles iCloud download and slow-mo AVCompositions.
    private static func exportSession(for asset: PHAsset, preset: QualityPreset) async throws -> AVAssetExportSession {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestExportSession(
                forVideo: asset, options: options, exportPreset: preset.exportPreset
            ) { session, _ in
                if let session {
                    continuation.resume(returning: session)
                } else {
                    continuation.resume(throwing: CompressError.loadFailed)
                }
            }
        }
    }
}
