import Foundation
import CryptoKit
import Photos

/// SHA-256 of the encoded file, checked against the actual saved Photos resource.
/// Streaming keeps verification memory bounded even for large videos.
enum MediaFingerprint {
    static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ asset: PHAsset, expected: String) async -> Bool {
        guard let resource = MediaSafety.resource(for: asset) else { return false }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let verifier = ResourceDigest()
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                verifier.add(data)
            } completionHandler: { error in
                continuation.resume(returning: error == nil && verifier.digest == expected)
            }
        }
    }
}

private final class ResourceDigest: @unchecked Sendable {
    private let lock = NSLock()
    private var hash = SHA256()
    func add(_ data: Data) { lock.lock(); defer { lock.unlock() }; hash.update(data: data) }
    var digest: String {
        lock.lock(); defer { lock.unlock() }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
