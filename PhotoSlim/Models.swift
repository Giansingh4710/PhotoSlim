import Foundation
import Photos

enum QualityPreset: String, CaseIterable, Identifiable {
    case high, medium, low

    var id: String { rawValue }

    var quality: Double {
        switch self {
        case .high: 0.8
        case .medium: 0.6
        case .low: 0.4
        }
    }

    var label: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
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
    /// The exact bytes we re-encoded from — kept so the compare view shows the same
    /// source pixels we measured against, not a separately-fetched thumbnail.
    let originalData: Data
    let originalSize: Int64
    let compressedURL: URL
    let compressedSize: Int64

    var id: String { original.localIdentifier }
    var savedBytes: Int64 { originalSize - compressedSize }
    var savedFraction: Double {
        originalSize > 0 ? Double(savedBytes) / Double(originalSize) : 0
    }
}

enum CompressError: LocalizedError {
    case loadFailed
    case decodeFailed
    case encodeFailed
    case saveFailed
    case noGain

    var errorDescription: String? {
        switch self {
        case .loadFailed: "Couldn't load the original photo."
        case .decodeFailed: "Couldn't read the photo data."
        case .encodeFailed: "Couldn't write the compressed photo."
        case .saveFailed: "Couldn't save the compressed photo to your library."
        case .noGain: "Already small — compressing wouldn't save space."
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
