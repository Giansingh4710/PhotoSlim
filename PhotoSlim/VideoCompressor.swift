import Foundation
import Photos
@preconcurrency import AVFoundation

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
        allowNetwork: Bool = true,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> (url: URL, compressedSize: Int64, originalSize: Int64) {
        let session = try await exportSession(for: asset, preset: preset, allowNetwork: allowNetwork)
        try Task.checkCancellation()
        let inputTracks = try await session.asset.load(.tracks)
        let inputVideo = try await session.asset.loadTracks(withMediaType: .video)
        let inputAudio = try await session.asset.loadTracks(withMediaType: .audio)
        guard inputVideo.count == 1, inputAudio.count <= 1,
              inputTracks.count == inputVideo.count + inputAudio.count,
              let videoTrack = inputVideo.first else { throw CompressError.unsafeMedia }
        let characteristics = try await videoTrack.load(.mediaCharacteristics)
        guard !characteristics.contains(.containsHDRVideo),
              !characteristics.contains(.containsAlphaChannel) else { throw CompressError.unsafeMedia }

        let url = Compressor.tempURL(ext: "mov")
        session.outputURL = url
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true
        // The export must never grow beyond the input while consuming disk headroom.
        session.fileLengthLimit = listedSize

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

        let cancellation = ExportCancellation(session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: { cancellation.cancel() }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { throw CancellationError() }
            throw CompressError.encodeFailed
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        // Judge the export against the *current* rendition, not the cached list
        // size — an edited video's cached size describes the untouched original,
        // which can dwarf (or trail) what the user actually has.
        let inputSize: Int64
        if listedSize > 0 { inputSize = listedSize } else { inputSize = await PhotoLibrary.byteSize(of: asset) }
        do {
            let output = AVURLAsset(url: url)
            let inputDuration = try await session.asset.load(.duration).seconds
            let outputDuration = try await output.load(.duration).seconds
            let outputAudio = try await output.loadTracks(withMediaType: .audio)
            let outputVideo = try await output.loadTracks(withMediaType: .video)
            let playable = try await output.load(.isPlayable)
            guard playable, inputDuration.isFinite, outputDuration.isFinite,
                  outputDuration > 0, abs(inputDuration - outputDuration) < 0.1,
                  inputAudio.count == outputAudio.count, outputVideo.count == 1 else { throw CompressError.encodeFailed }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard size > 0, size < inputSize else {
            try? FileManager.default.removeItem(at: url)
            throw CompressError.noGain(decoded: inputSize, compressed: size)
        }
        return (url: url, compressedSize: size, originalSize: inputSize)
    }

    /// One call handles iCloud download and slow-mo AVCompositions.
    /// `allowNetwork: false` throws .notOnDevice for iCloud-only videos instead.
    private static func exportSession(
        for asset: PHAsset, preset: QualityPreset, allowNetwork: Bool = true
    ) async throws -> AVAssetExportSession {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = allowNetwork

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestExportSession(
                forVideo: asset, options: options, exportPreset: preset.exportPreset
            ) { session, info in
                if let session {
                    continuation.resume(returning: session)
                } else if info?[PHImageResultIsInCloudKey] as? Bool == true {
                    continuation.resume(throwing: CompressError.notOnDevice)
                } else {
                    continuation.resume(throwing: CompressError.loadFailed)
                }
            }
        }
    }
}

/// AVFoundation supports cancelExport from the cancellation handler. Keep that narrow
/// thread-safe operation separate from the session's configuration and progress reads.
private final class ExportCancellation: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}
