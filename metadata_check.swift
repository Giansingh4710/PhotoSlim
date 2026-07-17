// Verifies the core claim: HEIC re-encode shrinks the file AND preserves EXIF/GPS.
// Mirrors Compressor.compress()'s ImageIO path exactly, minus PhotoKit.
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

/// Identical to Compressor.compress()'s encode step.
func compress(_ data: Data, quality: Double) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) > 0 else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        out, UTType.heic.identifier as CFString, 1, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImageFromSource(dest, source, 0, options as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

func props(_ data: Data) -> [CFString: Any] {
    let src = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
}

// --- run ---
let original = makeSourceJPEG()
guard let compressed = compress(original, quality: 0.8) else { fatalError("compress failed") }

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
