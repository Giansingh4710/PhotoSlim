import Foundation
import Photos
import AVFoundation

// Codable so a Slim All run can persist its chosen preset across a relaunch. The raw
// values are therefore a persistence contract too — don't rename them.
enum QualityPreset: String, CaseIterable, Identifiable, Codable {
    case high, medium, low

    var id: String { rawValue }

    /// Encoder quality. Lower values shrink harder. Tuned for already-HEIC iPhone
    /// photos, where a high value barely compresses — these give a visible saving
    /// while staying visually clean.
    var quality: Double {
        switch self {
        case .high: 0.5
        case .medium: 0.4
        case .low: 0.3
        }
    }

    /// Photo picker label — framed by the saving (what the user wants), with a
    /// reassuring quality note. "Low quality" scared people off the biggest saving
    /// even though a 0.3 HEIC re-encode is visually close to the original.
    var label: String {
        switch self {
        case .high: "Higher quality"
        case .medium: "Balanced"
        case .low: "Smaller file · more detail loss"
        }
    }

    /// Video tiers are resolution-based — AVAssetExportSession presets have no
    /// quality dial, so "harder" compression means a smaller frame.
    var exportPreset: String {
        switch self {
        case .high: AVAssetExportPresetHEVC1920x1080
        case .medium: AVAssetExportPreset1280x720
        case .low: AVAssetExportPreset960x540
        }
    }

    /// Video picker label — saving-first, with the resolution as the detail. Video
    /// tiers are resolution changes, so the resolution is the honest quality signal.
    var videoLabel: String {
        switch self {
        case .high: "Small saving · 1080p"
        case .medium: "Balanced · 720p"
        case .low: "Biggest saving · 540p"
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    // Raw values are a persistence contract (stored in UserDefaults) — do NOT rename
    // them, or saved preferences silently reset to the default on the next launch.
    case size = "size"
    case date = "date"

    var id: String { rawValue }
    var label: String { self == .size ? "Largest first" : "Newest first" }
    var systemImage: String { self == .size ? "arrow.down.circle" : "calendar" }
}

struct PhotoItem: Identifiable, Hashable {
    let asset: PHAsset
    let byteSize: Int64

    var id: String { asset.localIdentifier }

    static func == (a: PhotoItem, b: PhotoItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct CompressedResult: Identifiable {
    let original: PHAsset
    let originalSize: Int64
    let compressedURL: URL
    let compressedSize: Int64

    var id: String { original.localIdentifier }
    var isVideo: Bool { original.mediaType == .video }
    var savedBytes: Int64 { originalSize - compressedSize }
    var savedFraction: Double {
        originalSize > 0 ? Double(savedBytes) / Double(originalSize) : 0
    }
    var savedPercent: Int { Int(savedFraction * 100) }
}

enum CompressError: LocalizedError {
    case unsafeMedia
    case sourceChanged
    case lowSpace
    case operationBusy
    case loadFailed
    case notOnDevice   // original lives only in iCloud and network access was disallowed
    case decodeFailed
    case encodeFailed
    case noGain(decoded: Int64, compressed: Int64)

    var errorDescription: String? {
        switch self {
        // Media-neutral wording — these are thrown by both the photo and video pipelines.
        case .unsafeMedia: "This format may contain information that compression cannot preserve. The original was left untouched."
        case .sourceChanged: "The original changed or is no longer accessible. Please scan again. Nothing was deleted."
        case .lowSpace: "Not enough free space to create a copy safely. Free some space and try again."
        case .operationBusy: "Finish the other compression or review first."
        case .loadFailed: "Couldn't load the original."
        case .notOnDevice: "This item is stored in iCloud, not on this device."
        case .decodeFailed: "Couldn't read the photo data."
        case .encodeFailed: "Couldn't create the compressed copy."
        case let .noGain(decoded, compressed):
            "No saving at this quality: \(formatBytes(decoded)) → \(formatBytes(compressed)). "
            + "The original was left untouched."
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
