import Foundation

/// Launch-argument overrides for stress-testing Slim All on the simulator.
/// Every knob is nil unless its argument is present, and the parsing is compiled out
/// of release builds entirely — a missing argument always means production behavior.
///
/// Examples:
///   xcrun simctl launch booted <bundle-id> -slimFlushSize 3 -slimFakeFreeMB 600
///   Xcode scheme → Run → Arguments Passed On Launch
enum DebugKnobs {
#if DEBUG
    /// Delete prompt every N items instead of 25 — exercises many flushes fast.
    static let slimFlushSize = intArg("slimFlushSize")
    /// Fake free space (MB) reported by Compressor.availableBytes() — exercises the
    /// low-space pause and per-item headroom check without filling a real disk.
    static let fakeFreeMB = intArg("slimFakeFreeMB")
    /// Force a compression failure on every item whose stable id-hash % n == 0 —
    /// exercises the failure and retry paths.
    static let failEveryNth = intArg("slimFailEveryNth")
    private static func intArg(_ name: String) -> Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-\(name)"), args.indices.contains(i + 1) else { return nil }
        return Int(args[i + 1])
    }
#else
    static let slimFlushSize: Int? = nil
    static let fakeFreeMB: Int? = nil
    static let failEveryNth: Int? = nil
#endif
}

/// Order-stable, launch-stable hash for failure injection (String.hashValue is
/// re-seeded per process, which would break resume-and-retry scenarios).
func stableHash(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
}
