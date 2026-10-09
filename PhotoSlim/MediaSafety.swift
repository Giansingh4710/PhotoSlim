import Foundation
import Photos
import UniformTypeIdentifiers

/// Conservative allowlist: replacing an asset must not flatten its extra resources.
enum MediaSafety {
    static func resource(for asset: PHAsset) -> PHAssetResource? {
        guard asset.sourceType == .typeUserLibrary, !asset.isHidden,
              asset.burstIdentifier == nil, asset.canPerform(.delete) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.count == 1, let resource = resources.first else { return nil }
        if asset.mediaType == .image {
            guard asset.pixelWidth > 0, asset.pixelHeight > 0,
                  asset.pixelWidth <= 16_384, asset.pixelHeight <= 16_384,
                  Int64(asset.pixelWidth) * Int64(asset.pixelHeight) <= 50_000_000 else { return nil }
            let excluded: PHAssetMediaSubtype = [.photoLive, .photoHDR, .photoDepthEffect, .spatialMedia]
            guard asset.mediaSubtypes.intersection(excluded).isEmpty,
                  resource.type == .photo,
                  [UTType.jpeg.identifier, UTType.heic.identifier].contains(resource.uniformTypeIdentifier)
            else { return nil }
        } else if asset.mediaType == .video {
            // Slow motion, cinematic, spatial and HDR video need a dedicated pipeline.
            guard asset.mediaSubtypes.isEmpty, resource.type == .video else { return nil }
        } else { return nil }
        return resource
    }

    static func unchanged(_ source: PHAsset) -> Bool {
        guard let fresh = PHAsset.fetchAssets(withLocalIdentifiers: [source.localIdentifier], options: nil).firstObject
        else { return false }
        return resource(for: fresh) != nil && fresh.modificationDate == source.modificationDate
            && fresh.isFavorite == source.isFavorite && fresh.isHidden == source.isHidden
            && fresh.creationDate == source.creationDate
            && fresh.location?.coordinate.latitude == source.location?.coordinate.latitude
            && fresh.location?.coordinate.longitude == source.location?.coordinate.longitude
            && fresh.location?.altitude == source.location?.altitude
            && fresh.pixelWidth == source.pixelWidth && fresh.pixelHeight == source.pixelHeight
            && fresh.duration == source.duration
    }
}

/// One library writer across both media tabs and Slim All, including review sheets.
@MainActor
enum MediaOperation {
    private static var owner: UUID?
    static func acquire() -> UUID? {
        guard owner == nil else { return nil }
        let token = UUID()
        owner = token
        return token
    }
    static func release(_ token: UUID?) {
        if let token, owner == token { owner = nil }
    }
}
