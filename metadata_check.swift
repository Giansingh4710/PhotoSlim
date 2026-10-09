// Verifies the core claim: HEIC re-encode shrinks the file AND preserves EXIF/GPS.
// Compiles with production PhotoEncoder.swift and Models.swift; no mirrored encoder.
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

func makeSourceJPEG() -> Data {
    // Photographic-ish noise so JPEG can't trivially compress it to nothing.
    let w = 2000, h = 1500
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in stride(from: 0, to: h, by: 4) {
        for x in stride(from: 0, to: w, by: 4) {
            ctx.setFillColor(red: .random(in: 0...1), green: .random(in: 0...1),
                             blue: .random(in: 0...1), alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
    }
    let image = ctx.makeImage()!

    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: "2024:03:15 14:30:00",
        kCGImagePropertyExifLensModel: "Test Lens 50mm",
    ]
    let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: 37.7749,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 122.4194,
        kCGImagePropertyGPSLongitudeRef: "W",
    ]
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyGPSDictionary: gps,
        kCGImagePropertyOrientation: 1,
    ]

    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("fixture encode failed") }
    return data as Data
}

func props(_ data: Data) -> [CFString: Any] {
    let src = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
}

@main struct MetadataChecks {
static func main() throws {
// --- run ---
let original = makeSourceJPEG()
let compressed = try PhotoEncoder.encodeSmallest(original, preset: .high).data as Data

let op = props(original), cp = props(compressed)
let oExif = op[kCGImagePropertyExifDictionary] as! [CFString: Any]
let cExif = cp[kCGImagePropertyExifDictionary] as! [CFString: Any]
let oGPS = op[kCGImagePropertyGPSDictionary] as! [CFString: Any]
let cGPS = cp[kCGImagePropertyGPSDictionary] as! [CFString: Any]

// 1. smaller
assert(compressed.count < original.count,
       "not smaller: \(original.count) -> \(compressed.count)")
// 2. same pixels
assert(op[kCGImagePropertyPixelWidth] as! Int == cp[kCGImagePropertyPixelWidth] as! Int)
assert(op[kCGImagePropertyPixelHeight] as! Int == cp[kCGImagePropertyPixelHeight] as! Int)
// 3. date survives
assert(cExif[kCGImagePropertyExifDateTimeOriginal] as? String
       == oExif[kCGImagePropertyExifDateTimeOriginal] as? String,
       "date lost: \(String(describing: cExif[kCGImagePropertyExifDateTimeOriginal]))")
// 4. GPS survives
assert(cGPS[kCGImagePropertyGPSLatitude] as? Double == oGPS[kCGImagePropertyGPSLatitude] as? Double,
       "GPS lat lost")
assert(cGPS[kCGImagePropertyGPSLongitude] as? Double == oGPS[kCGImagePropertyGPSLongitude] as? Double,
       "GPS lon lost")
// 5. lens model survives (proves whole EXIF dict carried, not just known keys)
assert(cExif[kCGImagePropertyExifLensModel] as? String == "Test Lens 50mm", "lens lost")

let pct = 100 - Int(Double(compressed.count) / Double(original.count) * 100)
print("PASS  \(original.count / 1024)KB -> \(compressed.count / 1024)KB  (-\(pct)%)")
print("PASS  date, GPS lat/lon, lens model, dimensions all preserved")

// An animated input must never silently become its first frame.
let animated = NSMutableData()
let animationDestination = CGImageDestinationCreateWithData(animated, UTType.gif.identifier as CFString, 2, nil)!
let fixtureSource = CGImageSourceCreateWithData(original as CFData, nil)!
for _ in 0..<2 { CGImageDestinationAddImageFromSource(animationDestination, fixtureSource, 0, nil) }
precondition(CGImageDestinationFinalize(animationDestination))
do {
    _ = try PhotoEncoder.encodeSmallest(animated as Data, preset: .medium)
    fatalError("Animation was flattened")
} catch CompressError.unsafeMedia { print("PASS  animation refused without flattening") }

// EXIF rotations must remain attached to unchanged dimensions.
for orientation in [3, 6, 8] {
    let rotated = NSMutableData()
    let destination = CGImageDestinationCreateWithData(rotated, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImageFromSource(destination, fixtureSource, 0,
        [kCGImagePropertyOrientation: orientation] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    let output = try PhotoEncoder.encodeSmallest(rotated as Data, preset: .medium).data as Data
    precondition(props(output)[kCGImagePropertyOrientation] as? Int == orientation)
}
print("PASS  rotated photo orientations preserved")
do {
    _ = try PhotoEncoder.encodeSmallest(Data([0, 1, 2]), preset: .medium)
    fatalError("Corrupt input accepted")
} catch CompressError.decodeFailed { print("PASS  corrupt input rejected") }

do {
    _ = try PhotoEncoder.encodeSmallest(original.dropLast(300), preset: .medium)
    fatalError("Truncated JPEG accepted")
} catch CompressError.decodeFailed { print("PASS  truncated JPEG rejected before replacement") }

}
}
