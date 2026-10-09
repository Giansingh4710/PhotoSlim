import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoEncoder {
    /// Respect the selected quality; never silently lower it to force a saving.
    /// Autorelease pools bound ImageIO temporaries to one item.
    static func encodeSmallest(
        _ data: Data, preset: QualityPreset
    ) throws -> (data: NSData, size: Int64) {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw CompressError.decodeFailed
            }
            guard let sourceType = CGImageSourceGetType(source) as String?,
                  [UTType.jpeg.identifier, UTType.heic.identifier].contains(sourceType) else {
                throw CompressError.unsafeMedia
            }
            // ImageIO can report a truncated JPEG as complete and silently fill the
            // missing pixels. Require its end-of-image marker before re-encoding.
            // JPEGs with unsupported trailing payloads are conservatively skipped.
            if sourceType == UTType.jpeg.identifier, data.suffix(2) != Data([0xff, 0xd9]) {
                throw CompressError.decodeFailed
            }

            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            guard properties?[kCGImagePropertyHasAlpha] as? Bool != true,
                  (properties?[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else { throw CompressError.unsafeMedia }
            guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties?[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_384, height <= 16_384,
                  Int64(width) * Int64(height) <= 50_000_000 else { throw CompressError.unsafeMedia }
            let originalSize = Int64(data.count)
            guard CGImageSourceGetCount(source) == 1 else { throw CompressError.unsafeMedia }
            for type in [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                         kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeHDRGainMap] {
                if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil {
                    throw CompressError.unsafeMedia
                }
            }
            guard let encoded = encodeHEIC(source, quality: preset.quality) else { throw CompressError.encodeFailed }
            let size = Int64(encoded.length)
            guard size < originalSize else {
                throw CompressError.noGain(decoded: originalSize, compressed: size)
            }
            let smallest = (data: encoded, size: size)
            return smallest
        }
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
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        guard let check = CGImageSourceCreateWithData(out, nil),
              CGImageSourceGetStatus(check) == .statusComplete,
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let encoded = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any],
              original[kCGImagePropertyPixelWidth] as? Int == encoded[kCGImagePropertyPixelWidth] as? Int,
              original[kCGImagePropertyPixelHeight] as? Int == encoded[kCGImagePropertyPixelHeight] as? Int,
              (original[kCGImagePropertyOrientation] as? Int ?? 1) == (encoded[kCGImagePropertyOrientation] as? Int ?? 1),
              CGImageSourceCreateImageAtIndex(check, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
        else { return nil }
        return out
    }

}
