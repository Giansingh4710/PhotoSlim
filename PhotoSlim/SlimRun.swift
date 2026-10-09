import Foundation
import Photos

/// One entry in a Slim All run queue. Kept deliberately small — a 40k-item library means
/// 40k of these encoded into one plan file.
struct SlimPlanItem: Codable {
    let id: String        // the original PHAsset's localIdentifier
    let bytes: Int64      // listed size at plan time; feeds compressToTemp and the space math
    let isVideo: Bool

    var sourceModifiedAt: Date?
    var copyModifiedAt: Date?
    var copySHA256: String?
    var state: State = .pending
    var newID: String?          // the copy's localIdentifier, recorded the instant it exists
    var savedBytes: Int64 = 0   // counted only after confirmed deletion

    enum State: String, Codable {
        case pending      // untouched
        case copied       // copy exists, ORIGINAL STILL EXISTS — the duplicate window
        case done         // copy exists and the original is confirmed gone
        case failedKept   // couldn't compress or copy; original left alone, nothing created
        case skipped      // excluded at plan time, or vanished from the library
    }
}

/// The durable record of a Slim All run. Replayed on launch so a killed run resumes
/// instead of restarting — and, more importantly, so we can tell whether any originals
/// are sitting in the duplicate window awaiting deletion.
struct SlimRun: Codable {
    /// Unsupported versions block recovery and are retained for manual review.
    var version = 2

    let startedAt: Date
    let preset: QualityPreset
    let mode: Mode
    let chunkSize: Int          // 0 when not chunking
    var items: [SlimPlanItem]

    var savedBytes: Int64 = 0
    var doneCount = 0
    var failedCount = 0

    // Rebuilt once after loading; keep transition checks linear over the whole run.
    private var sourceIDs: Set<String> = []
    private var copyOwners: [String: Int] = [:]
    private enum CodingKeys: String, CodingKey {
        case version, startedAt, preset, mode, chunkSize, items, savedBytes, doneCount, failedCount
    }

    init(startedAt: Date, preset: QualityPreset, mode: Mode, chunkSize: Int, items: [SlimPlanItem]) {
        self.startedAt = startedAt
        self.preset = preset
        self.mode = mode
        self.chunkSize = chunkSize
        self.items = items
    }

    enum Mode: String, Codable { case chunked, headroom }

    /// Derived, never stored — so it can't drift out of sync with `items`.
    var pendingDeleteIDs: [String] { items.filter { $0.state == .copied && $0.newID != nil && $0.newID != $0.id }.map(\.id) }

    /// Next item to process. The loop is strictly sequential, so the first pending entry
    /// is the cursor — no separate bookkeeping to keep consistent.
    var cursor: Int? { items.firstIndex { $0.state == .pending } }

    var remainingCount: Int { items.filter { $0.state == .pending }.count }
    var isFinished: Bool { cursor == nil && pendingDeleteIDs.isEmpty }
}

/// One state transition, appended to the log.
struct SlimTransition: Codable {
    let i: Int                  // index into SlimRun.items
    let s: SlimPlanItem.State
    let n: String?              // newID, when moving to .copied
    let b: Int64?               // savedBytes, when known
    var m: Date? = nil          // copy version verified before deleting either side
    var h: String? = nil        // exact encoded resource digest
}

/// Plan + write-ahead log on disk.
///
/// Two files rather than one rewritten blob: a 40k-item plan encodes to megabytes, and
/// rewriting that after every item would be slower than the compression itself. Appending
/// a small transition avoids rewriting the entire plan. Each append is synchronized.
/// A corrupt or torn log blocks further processing and preserves all remaining media.
///
/// Lives in Application Support so cache eviction under disk pressure cannot remove
/// the recovery record. PhotoLibrary's regenerable size cache belongs in Caches;
/// these source/copy identities do not.
enum SlimRunStore {
    #if SAFETY_CHECKS
    static var testDirectory: URL?
    #endif
    private static var directory: URL {
        #if SAFETY_CHECKS
        if let testDirectory { return testDirectory }
        #endif
        return URL.applicationSupportDirectory
    }
    private static var planURL: URL { directory.appendingPathComponent("slim-plan.json") }
    private static var logURL: URL { directory.appendingPathComponent("slim-log.jsonl") }

    static var hasRun: Bool {
        FileManager.default.fileExists(atPath: planURL.path) || FileManager.default.fileExists(atPath: logURL.path)
    }

    /// Writes the immutable plan and truncates any previous log.
    static func writePlan(_ run: SlimRun) throws {
        var checked = run
        try checked.validate()
        guard checked.items.allSatisfy({ $0.state == .pending }) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Never replace an unresolved run, or let a stale log apply to a new plan.
        guard !hasRun else { throw CocoaError(.fileWriteFileExists) }
        try Data().write(to: logURL, options: .atomic)
        try JSONEncoder().encode(run).write(to: planURL, options: .atomic)
        for url in [planURL, logURL] {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        }
    }

    /// Loads the plan and replays every logged transition over it.
    static func load() -> SlimRun? {
        guard let data = try? Data(contentsOf: planURL),
              var run = try? JSONDecoder().decode(SlimRun.self, from: data),
              (try? run.validate()) != nil
        else { return nil }

        guard let logData = try? Data(contentsOf: logURL),
              let text = String(data: logData, encoding: .utf8),
              logData.isEmpty || logData.last == 0x0A
        else { return nil }

        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            // Corrupt/torn logs stop recovery; never append behind an incomplete record.
            guard let lineData = line.data(using: .utf8),
                  let t = try? decoder.decode(SlimTransition.self, from: lineData),
                  let updated = try? run.applying(t)
            else { return nil }
            run.publish(updated, at: t.i)
        }
        run.recomputeTotals()
        return run
    }

    /// Appends one transition. Must reach disk before the caller proceeds — this is the
    /// durability point that makes the duplicate window recoverable.
    static func append(_ transition: SlimTransition) throws {
        var line = try JSONEncoder().encode(transition)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    static func clear() throws {
        for url in [planURL, logURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

extension SlimRun {
    mutating func validate() throws {
        guard version == 2, chunkSize >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        sourceIDs = Set(items.map(\.id))
        copyOwners = [:]
        guard sourceIDs.count == items.count else { throw CocoaError(.fileReadCorruptFile) }
        var total: Int64 = 0
        for (index, item) in items.enumerated() {
            let (next, overflow) = total.addingReportingOverflow(item.bytes)
            guard !item.id.isEmpty, item.bytes > 0, !overflow else { throw CocoaError(.fileReadCorruptFile) }
            total = next
            try validate(item, at: index)
            if let copy = item.newID { copyOwners[copy] = index }
        }
    }

    private func validate(_ item: SlimPlanItem, at index: Int) throws {
        guard item.savedBytes >= 0, item.savedBytes < item.bytes else { throw CocoaError(.fileReadCorruptFile) }
        if item.state == .copied || item.state == .done {
            guard let copy = item.newID, !copy.isEmpty, !sourceIDs.contains(copy),
                  copyOwners[copy] == nil || copyOwners[copy] == index,
                  let digest = item.copySHA256, digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  item.savedBytes > 0 else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            guard item.newID == nil, item.copySHA256 == nil, item.copyModifiedAt == nil,
                  item.savedBytes == 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    fileprivate mutating func applying(_ t: SlimTransition) throws -> SlimPlanItem {
        if sourceIDs.isEmpty { try validate() }
        guard items.indices.contains(t.i) else { throw CocoaError(.fileReadCorruptFile) }
        var item = items[t.i]
        switch (item.state, t.s) {
        case (.pending, .copied):
            item.newID = t.n
            item.savedBytes = t.b ?? 0
            item.copyModifiedAt = t.m
            item.copySHA256 = t.h
        case (.copied, .done):
            guard t.n == nil, t.b == nil, t.m == nil, t.h == nil else { throw CocoaError(.fileReadCorruptFile) }
        case (.pending, .failedKept), (.pending, .skipped), (.copied, .pending),
             (.copied, .skipped), (.failedKept, .pending):
            guard t.n == nil, t.b == nil, t.m == nil, t.h == nil else { throw CocoaError(.fileReadCorruptFile) }
            item.newID = nil
            item.savedBytes = 0
            item.copyModifiedAt = nil
            item.copySHA256 = nil
        default: throw CocoaError(.fileReadCorruptFile)
        }
        item.state = t.s
        try validate(item, at: t.i)
        return item
    }

    fileprivate mutating func publish(_ item: SlimPlanItem, at index: Int) {
        if let old = items[index].newID { copyOwners.removeValue(forKey: old) }
        if let copy = item.newID { copyOwners[copy] = index }
        items[index] = item
    }

    mutating func recomputeTotals() {
        savedBytes = items.filter { $0.state == .done }.reduce(0) { $0 + $1.savedBytes }
        doneCount = items.count { $0.state == .done }
        failedCount = items.count { $0.state == .failedKept }
    }

    /// Persist and synchronize before publishing the transition in memory.
    mutating func record(_ index: Int, _ state: SlimPlanItem.State, newID: String? = nil, savedBytes: Int64? = nil, copyModifiedAt: Date? = nil, copySHA256: String? = nil) throws {
        let transition = SlimTransition(i: index, s: state, n: newID, b: savedBytes, m: copyModifiedAt, h: copySHA256)
        let updated = try applying(transition)
        try SlimRunStore.append(transition)
        publish(updated, at: index)
    }
}

/// What reconciliation found when the app came back to a run in progress.
struct ReconcileReport {
    var duplicatesPending = 0    // items still in the .copied window
    var duplicateBytes: Int64 = 0
    var remaining = 0
    var orphanSuspected = false  // the one item that may have been copied without a log entry

    var needsCleanup: Bool { duplicatesPending > 0 }
}

extension SlimRun {
    /// Reconciles the log against the actual photo library.
    ///
    /// The log tells us what we *intended*; only the library knows what happened. A crash
    /// between `createOne` returning and the log append leaves them disagreeing, so every
    /// non-terminal item is re-resolved and classified against reality:
    ///
    ///   original alive │ copy alive │ meaning                        │ action
    ///   ───────────────┼────────────┼────────────────────────────────┼──────────────────
    ///        yes       │    yes     │ true duplicate                 │ stays .copied
    ///        no        │    yes     │ delete landed, log missed it   │ → .done
    ///        yes       │    no      │ copy rolled back or removed    │ → .pending (retry)
    ///        no        │    no      │ user deleted both              │ → .skipped
    ///
    /// Nothing is ever deleted here — this only classifies. Deletion stays in the flush,
    /// behind the user's prompt.
    mutating func reconcile() throws -> ReconcileReport {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw CocoaError(.fileReadNoPermission)
        }
        var report = ReconcileReport()

        let candidates = items.indices.filter { items[$0].state == .copied }
        var lookup = Set(candidates.map { items[$0].id })
        for i in candidates { if let n = items[i].newID { lookup.insert(n) } }

        var alive = Set<String>()
        if !lookup.isEmpty {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(lookup), options: nil)
            fetched.enumerateObjects { asset, _, _ in alive.insert(asset.localIdentifier) }
        }

        for i in candidates {
            let originalAlive = alive.contains(items[i].id)
            let copyAlive = items[i].newID.map { alive.contains($0) } ?? false

            switch (originalAlive, copyAlive) {
            case (true, true):
                report.duplicatesPending += 1
                report.duplicateBytes += items[i].bytes
            case (false, true):
                try record(i, .done)
            case (true, false):
                try record(i, .pending)
            case (false, false):
                try record(i, .skipped)
            }
        }

        // Photos may save an item before the process receives its ID. This can happen
        // on the very first item too, with no .copied entries yet. Do not infer that
        // an empty duplicate window proves a clean stop, and never guess a copy ID.
        report.orphanSuspected = report.duplicatesPending > 0 || remainingCount > 0
        report.remaining = remainingCount

        recomputeTotals()
        return report
    }
}
