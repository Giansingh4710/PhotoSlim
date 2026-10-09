#!/usr/bin/env swift
//
// Seeds the booted iOS simulator's photo library with test media for Slim All runs.
//
//     swift scripts/seed_simulator.swift [photoCount] [videoCount]
//
// Defaults: 120 photos, 4 videos. Photos carry EXIF DateTimeOriginal spread over
// ~8 years (oldest first by filename), so the simulator library gets a realistic
// date spread and the oldest-first plan order is meaningful. Three photo flavors:
//   • gradient  — compresses well (the normal savings path)
//   • noise     — a large JPEG for the default 5 MB photo filter
//   • large     — 4000px gradients (bigger byte sizes, headroom math)
// Videos are short H.264 clips; HEVC re-export shrinks them.
//
// Requires a booted simulator: xcrun simctl boot "iPhone 16" (or run from Xcode once).

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

let simulatorID = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "booted"

let photoCount = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 120 : 120
let videoCount = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 4 : 4

let outDir = URL(fileURLWithPath: "seed-media", isDirectory: true)
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Image generation

func makeContext(_ size: Int) -> CGContext {
    CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
}

func gradientImage(_ size: Int, seed: Int) -> CGImage {
    let ctx = makeContext(size)
    let colors = [
        CGColor(red: Double(seed % 7) / 7.0, green: 0.3, blue: 0.8, alpha: 1),
        CGColor(red: 0.9, green: Double(seed % 5) / 5.0, blue: 0.2, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: .zero,
        end: CGPoint(x: size, y: size), options: []
    )
    return ctx.makeImage()!
}

func noiseImage(_ size: Int) -> CGImage {
    let ctx = makeContext(size)
    let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * size)
    for i in 0..<(ctx.bytesPerRow * size) { buf[i] = UInt8.random(in: 0...255) }
    return ctx.makeImage()!
}

let exifFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

func writeJPEG(_ image: CGImage, to url: URL, date: Date, quality: Double) {
    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: exifFormatter.string(from: date),
            kCGImagePropertyExifDateTimeDigitized: exifFormatter.string(from: date),
        ],
    ]
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("JPEG write failed: \(url.lastPathComponent)") }
}

// Oldest first: item 0 gets the oldest date. ~8 years spread.
let start = Date().addingTimeInterval(-8 * 365 * 24 * 3600)
let step = (8 * 365 * 24 * 3600.0) / Double(max(photoCount, 1))

print("Generating \(photoCount) photos…")
for i in 0..<photoCount {
    let date = start.addingTimeInterval(Double(i) * step)
    let name = String(format: "seed-%04d", i)
    let url = outDir.appendingPathComponent("\(name).jpg")
    switch i % 5 {
    case 0:  writeJPEG(noiseImage(2400), to: url, date: date, quality: 0.98)
    case 1:  writeJPEG(gradientImage(4000, seed: i), to: url, date: date, quality: 0.98) // large
    default: writeJPEG(gradientImage(2000, seed: i), to: url, date: date, quality: 0.95) // normal
    }
}

// MARK: - Video generation (short H.264 clips of animated color)

func writeVideo(to url: URL, seconds: Int, date: Date) throws {
    let size = CGSize(width: 1280, height: 720)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000], // fat on purpose
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height,
    ])
    let meta = AVMutableMetadataItem()
    meta.identifier = .quickTimeMetadataCreationDate
    meta.value = ISO8601DateFormatter().string(from: date) as NSString
    writer.metadata = [meta]

    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let fps = 30
    for frame in 0..<(seconds * fps) {
        while !input.isReadyForMoreMediaData { usleep(5_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let pixelBuffer = pb else { fatalError("pixel buffer") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )!
        let hue = Double(frame) / Double(seconds * fps)
        ctx.setFillColor(CGColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        // Moving box so inter-frame compression has real work to do.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: Double(frame % 1200), y: 300, width: 120, height: 120))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { fatalError("video write failed: \(String(describing: writer.error))") }
}

print("Generating \(videoCount) videos…")
for i in 0..<videoCount {
    let date = start.addingTimeInterval(Double(i) * step * Double(photoCount) / Double(max(videoCount, 1)))
    try writeVideo(to: outDir.appendingPathComponent(String(format: "seed-vid-%02d.mov", i)), seconds: 3, date: date)
}

// MARK: - Import into the booted simulator

let files = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
    .map(\.path).sorted()
print("Importing \(files.count) files into simulator \(simulatorID)…")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
task.arguments = ["simctl", "addmedia", simulatorID] + files
try task.run()
task.waitUntilExit()
if task.terminationStatus == 0 {
    print("Done. Grant photo access with:\n  xcrun simctl privacy booted grant photos <bundle-id>")
} else {
    print("simctl addmedia failed (\(task.terminationStatus)) — is a simulator booted?")
}
