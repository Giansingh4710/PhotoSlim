// Compile this runner WITH production SlimRun.swift; it never opens a photo library.
// swiftc -D SAFETY_CHECKS PhotoSlim/SlimRun.swift PhotoSlim/StorageSafety.swift slim_run_check.swift -o /tmp/photoslim-recovery-check
import Foundation

enum QualityPreset: String, Codable { case high, medium, low }

@main struct RecoveryChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SlimRunStore.testDirectory = root
        defer { try? FileManager.default.removeItem(at: root) }
        func fresh() -> SlimRun {
            SlimRun(startedAt: Date(), preset: .medium, mode: .chunked, chunkSize: 25,
                    items: (0..<3).map { SlimPlanItem(id: "original-\($0)", bytes: 1000, isVideo: false) })
        }
        func expectThrow(_ label: String, _ action: () throws -> Void) {
            do { try action(); fatalError("FAIL: \(label)") } catch { print("PASS: \(label)") }
        }
        let digest = String(repeating: "a", count: 64)
        var run = fresh()
        try SlimRunStore.writePlan(run)
        expectThrow("cannot overwrite an unresolved plan") { try SlimRunStore.writePlan(fresh()) }
        try run.record(0, .copied, newID: "copy-0", savedBytes: 500, copySHA256: digest)
        try run.record(0, .done)
        try run.record(1, .copied, newID: "copy-1", savedBytes: 200, copySHA256: digest)
        let restored = SlimRunStore.load()!
        precondition(restored.items[0].newID == "copy-0" && restored.savedBytes == 500)
        precondition(restored.pendingDeleteIDs == ["original-1"])
        print("PASS: production log replay preserves copy identities and confirmed totals")
        expectThrow("cannot authorize deletion without a distinct copy") { try run.record(2, .copied, newID: "original-2", savedBytes: 100, copySHA256: digest) }
        try run.record(1, .pending)
        precondition(SlimRunStore.load()!.items[1].newID == nil)
        print("PASS: reset clears stale copy identity on disk")

        // Simulates a full disk/unwritable log: publish no in-memory deletion state.
        let log = root.appendingPathComponent("slim-log.jsonl")
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
        expectThrow("failed checkpoint write stops transition") { try run.record(2, .copied, newID: "copy-2", savedBytes: 100, copySHA256: digest) }
        precondition(run.items[2].state == .pending && run.items[2].newID == nil)
        precondition(SlimRunStore.load() == nil)
        print("PASS: unreadable log fails closed")
        try FileManager.default.removeItem(at: log)
        try Data("{\"i\":2,\"s\":\"cop".utf8).write(to: log)
        precondition(SlimRunStore.load() == nil)
        print("PASS: torn log cannot resume deletion")
        try SlimRunStore.clear()
        try SlimRunStore.writePlan(fresh())
        try SlimRunStore.append(SlimTransition(i: 2, s: .copied, n: nil, b: nil))
        precondition(SlimRunStore.load() == nil)
        print("PASS: malformed copied state cannot resume deletion")
        try SlimRunStore.clear()
        var duplicate = fresh()
        duplicate.items.append(duplicate.items[0])
        expectThrow("invalid plan is rejected before writing") { try SlimRunStore.writePlan(duplicate) }
        print("PASS: duplicate source identifiers fail closed")
        try SlimRunStore.clear()
        run = fresh()
        try SlimRunStore.writePlan(run)
        expectThrow("copy cannot point to another original") {
            try run.record(0, .copied, newID: "original-1", savedBytes: 500, copySHA256: digest)
        }
        expectThrow("cannot mark an untouched original deleted") { try run.record(0, .done) }
        expectThrow("copy needs a recorded digest") { try run.record(0, .copied, newID: "copy-0", savedBytes: 500) }
        expectThrow("negative savings fail closed") {
            try run.record(0, .copied, newID: "copy-0", savedBytes: -1, copySHA256: digest)
        }
        try run.record(0, .copied, newID: "copy-0", savedBytes: 500, copySHA256: digest)
        expectThrow("two originals cannot share one copy") {
            try run.record(1, .copied, newID: "copy-0", savedBytes: 200, copySHA256: digest)
        }
        precondition(SlimRunStore.load()!.items[0].copySHA256 == digest)
        try run.record(0, .pending)
        let reset = SlimRunStore.load()!.items[0]
        precondition(reset.newID == nil && reset.copySHA256 == nil && reset.savedBytes == 0)
        print("PASS: retry clears identity, digest and savings together")

        // A syntactically complete record without its delimiter is still a torn append.
        try SlimRunStore.clear()
        try SlimRunStore.writePlan(fresh())
        let transition = SlimTransition(i: 0, s: .copied, n: "copy-0", b: 500, h: digest)
        try JSONEncoder().encode(transition).write(to: log)
        precondition(SlimRunStore.load() == nil)
        print("PASS: missing log delimiter fails closed")

        // Orphaned journals and old plans must never authorize a new destructive run.
        try FileManager.default.removeItem(at: root.appendingPathComponent("slim-plan.json"))
        precondition(SlimRunStore.hasRun && SlimRunStore.load() == nil)
        expectThrow("orphan journal blocks a new plan") { try SlimRunStore.writePlan(fresh()) }
        try SlimRunStore.clear()
        var old = fresh()
        old.version = 1
        expectThrow("legacy plans without fingerprints are rejected") { try SlimRunStore.writePlan(old) }
        var oversized = fresh()
        oversized.items = [SlimPlanItem(id: "a", bytes: .max, isVideo: false),
                           SlimPlanItem(id: "b", bytes: .max, isVideo: false)]
        expectThrow("overflowing size totals are rejected") { try SlimRunStore.writePlan(oversized) }

        let reserve = StorageSafety.reserveBytes
        precondition(!StorageSafety.hasHeadroom(free: nil, bytes: 100))
        precondition(!StorageSafety.hasHeadroom(free: -1, bytes: 100))
        precondition(!StorageSafety.hasHeadroom(free: .max, bytes: .max))
        precondition(!StorageSafety.hasHeadroom(free: .max, bytes: 0))
        precondition(!StorageSafety.hasHeadroom(free: reserve + 199, bytes: 100))
        precondition(StorageSafety.hasHeadroom(free: reserve + 200, bytes: 100))
        print("PASS: unknown capacity, overflow and insufficient storage block writes")
        print("All production recovery and storage checks passed.")
    }
}
