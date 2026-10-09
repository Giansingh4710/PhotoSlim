import Foundation
import Photos
import SwiftUI

/// Whole-library sequential compression.
///
/// Why this exists separately from `Compressor.bulkCompressAndDelete`: the bulk path
/// commits a whole batch of creates in one transaction, which makes every copy in that
/// batch share a "date added" and land in Recently Added in arbitrary order. Slim All
/// trades that efficiency away — one transaction per asset, oldest first — because
/// insertion order is the only control iOS gives us over Recently Added.
enum SlimEngine {

    /// Originals awaiting deletion before we flush. Every flush costs the user one iOS
    /// confirmation prompt, and until it lands those items exist twice.
    ///   • smaller → more prompts, fewer duplicates exposed to a crash
    ///   • larger  → fewer prompts, a bigger mess to reconcile if the app dies
    /// 25 puts a 5,000-item library at ~200 prompts and caps crash exposure at 25 items.
    static var deleteFlushSize: Int { max(1, min(100, DebugKnobs.slimFlushSize ?? 25)) }

    /// Stop and hand back to the user rather than filling the disk completely. Deleted
    /// originals free nothing for 30 days, so headroom only shrinks during a run.
    static let minFreeBytes = StorageSafety.reserveBytes

    // MARK: - Plan

    struct Plan {
        var items: [SlimPlanItem]
        var totalBytes: Int64
        var skippedCount: Int      // excluded up front (multi-resource, Live Photos)
    }

    /// Snapshots the library oldest-first, photos and videos together.
    ///
    /// The plan is built ONCE and persisted. That's what makes the run idempotent: copies
    /// created during the run were not in the library at plan time, so they can never be
    /// picked up and re-compressed by their own run.
    static func buildPlan(onProgress: @escaping @MainActor (Double) -> Void) async -> Plan {
        let options = PHFetchOptions()
        // Oldest first — the whole point. Each copy is inserted after the previous one,
        // so date-added ends up ascending in date-taken order.
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Live Photos pair a still with a video and would need both re-encoded and
        // re-paired — same exclusion the per-type tabs use.
        options.predicate = NSPredicate(
            format: "(mediaType == %d OR mediaType == %d) AND NOT ((mediaSubtypes & %d) != 0)",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue,
            PHAssetMediaSubtype.photoLive.rawValue
        )

        let result = PHAsset.fetchAssets(with: options)
        var items: [SlimPlanItem] = []
        var totalBytes: Int64 = 0
        var skipped = 0
        let total = max(result.count, 1)
        // The tabs' size caches usually already cover most of the library — a cold
        // per-asset resource lookup for tens of thousands of items takes minutes.
        let cachedSizes = PhotoLibrary.cachedSizes()

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        for (index, asset) in assets.enumerated() {
            guard !Task.isCancelled else { break }
            if MediaSafety.resource(for: asset) == nil {
                skipped += 1
            } else {
                var size = cachedSizes[PhotoLibrary.cacheKey(asset)] ?? 0
                if size == 0 { size = await PhotoLibrary.byteSize(of: asset) }
                guard size > 0 else { skipped += 1; continue }
                items.append(SlimPlanItem(
                    id: asset.localIdentifier,
                    bytes: size,
                    isVideo: asset.mediaType == .video,
                    sourceModifiedAt: asset.modificationDate
                ))
                totalBytes += size
            }
            await onProgress(Double(index + 1) / Double(total))
            if index % 50 == 0 { await Task.yield() }
        }

        return Plan(items: items, totalBytes: totalBytes, skippedCount: skipped)
    }

    // MARK: - One item

    enum ItemOutcome {
        case copied(newID: String, savedBytes: Int64, modifiedAt: Date?, sha256: String)
        case failed        // nothing created, original untouched
        case vanished      // no longer in the library
        case notOnDevice   // original lives only in iCloud — on-device run leaves it alone
    }

    /// Compress at the chosen quality, then create a copy only if it is smaller.
    /// Never deletes — deletion is batched into the flush so the user isn't prompted
    /// per item.
    static func processOne(
        _ item: SlimPlanItem,
        preset: QualityPreset,
        albums: [PHAssetCollection],
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async -> ItemOutcome {
        // Re-fetch: a resumed run's PHAssets are stale, and the user may have deleted
        // things in Photos since the plan was built.
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
        guard let asset = fetched.firstObject else { return .vanished }
        guard MediaSafety.resource(for: asset) != nil,
              let modified = item.sourceModifiedAt, modified == asset.modificationDate,
              !Task.isCancelled else { return .failed }

        do {
            if let n = DebugKnobs.failEveryNth, n > 0, stableHash(item.id) % n == 0 {
                throw CompressError.encodeFailed
            }
            let (url, compressedSize, originalSize) = try await Compressor.compressToTemp(
                asset: asset, preset: preset, listedSize: item.bytes,
                allowNetwork: false, onProgress: onProgress
            )
            defer { try? FileManager.default.removeItem(at: url) }
            try Task.checkCancellation()
            let digest = try MediaFingerprint.file(url)
            let newID = try await Compressor.createOne(source: asset, url: url, filename: nil, albums: albums)
            let copy = PHAsset.fetchAssets(withLocalIdentifiers: [newID], options: nil).firstObject
            return .copied(newID: newID, savedBytes: originalSize - compressedSize, modifiedAt: copy?.modificationDate, sha256: digest)
        } catch CompressError.notOnDevice {
            return .notOnDevice
        } catch { return .failed }

    }
}

// MARK: - Model

@MainActor
@Observable
final class SlimEverythingModel {

    enum Phase {
        case idle
        case denied(PHAuthorizationStatus)
        case scanning
        case confirm(SlimEngine.Plan)
        case running
        case paused(reason: PauseReason)
        case resumePrompt(ReconcileReport)
        case done(summary: String)
    }

    enum PauseReason {
        case chunkComplete(freedHint: Int64)
        case lowSpace
        case declined          // user declined a delete prompt
        case deleteStalled     // iOS never confirmed a delete (known hang) — retry on resume
        case safetyStop
        case userPaused
    }

    private(set) var phase: Phase = .idle
    private(set) var scanProgress: Double = 0
    private(set) var run: SlimRun?

    // Live progress
    private(set) var processed = 0
    private(set) var total = 0
    private(set) var savedBytes: Int64 = 0
    private(set) var pendingDeletes = 0
    private(set) var currentAsset: PHAsset?
    private(set) var itemProgress: Double?
    private(set) var startedAt: Date?
    /// True until the in-flight item reaches a clean boundary. Export cancellation
    /// and any already-submitted Photos change must acknowledge completion first.
    private(set) var isPausing = false
    private(set) var isRecovering = false

    private var task: Task<Void, Never>?
    private var operationToken: UUID?
    private(set) var safetyMessage = ""

    private func stopForSafety(_ error: Error) {
        safetyMessage = "Stopped safely: \(error.localizedDescription) No further originals will be deleted. Any saved copies and recovery records are kept. Review your library before continuing."
        endRunEnvironment()
        phase = .paused(reason: .safetyStop)
    }
    private var albumIndex: [String: [PHAssetCollection]] = [:]
    /// Items already processed when this session's loop started — the ETA divides
    /// session work by session time; mixing all-time counts with session elapsed
    /// produces absurd estimates on every resume.
    private var sessionBaseProcessed = 0

    var isRunning: Bool { if case .running = phase { return true }; return false }

    /// Rough remaining time from observed throughput. Coarse on purpose — this run takes
    /// hours and a precise-looking number would just be wrong.
    var eta: String? {
        let sessionDone = processed - sessionBaseProcessed
        guard let startedAt, sessionDone > 5, processed < total else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = elapsed / Double(sessionDone) * Double(total - processed)
        guard remaining.isFinite, remaining > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = remaining > 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: remaining)
    }

    // MARK: Entry

    /// Called when the tab appears. Picks up an interrupted run before offering a new one.
    func refreshAuthorization() async {
        if case .denied = phase { phase = .idle; await start() }
    }

    func start() async {
        do { try await startSafely() } catch { stopForSafety(error) }
    }

    private func startSafely() async throws {
        guard case .idle = phase else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        if var existing = SlimRunStore.load() {
            let report = try existing.reconcile()
            run = existing
            if report.needsCleanup || report.remaining > 0 {
                phase = .resumePrompt(report)
                return
            }
            // Nothing left to do — a previous run finished but never cleared.
            try SlimRunStore.clear()
            run = nil
        }
        if SlimRunStore.hasRun { throw CocoaError(.fileReadCorruptFile) }
    }

    func scan() async {
        do { try await scanSafely() } catch { stopForSafety(error) }
    }

    private func scanSafely() async throws {
        guard case .idle = phase, !isPausing, !isRecovering else { return }
        guard let token = MediaOperation.acquire() else { throw CompressError.operationBusy }
        defer { MediaOperation.release(token) }
        phase = .scanning
        // Never build a fresh plan while a stored run has unresolved items. A run
        // abandoned mid-window has copies AND originals both in the library; a new plan
        // would list them as separate items and compress both — permanent duplicates.
        if var existing = SlimRunStore.load() {
            let report = try existing.reconcile()
            if report.needsCleanup || report.remaining > 0 {
                run = existing
                phase = .resumePrompt(report)
                return
            }
            try SlimRunStore.clear()
            run = nil
        }

        guard !SlimRunStore.hasRun else { throw CocoaError(.fileReadCorruptFile) }

        // The other tabs request access in their own flow; a user can land here first.
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            phase = .denied(status)
            return
        }

        phase = .scanning
        scanProgress = 0
        let plan = await SlimEngine.buildPlan { [weak self] fraction in
            self?.scanProgress = fraction
        }
        try Task.checkCancellation()
        phase = .confirm(plan)
    }

    func cancelToIdle() {
        guard !isPausing, !isRecovering else { return }
        isPausing = true
        let previous = task
        previous?.cancel()
        task = Task {
            await previous?.value
            endRunEnvironment()
            isPausing = false
            phase = .idle
        }
    }

    // MARK: Run

    func begin(plan: SlimEngine.Plan, preset: QualityPreset, mode: SlimRun.Mode, chunkSize: Int) {
        guard case .confirm = phase, !isPausing, !isRecovering, acquireOperation() else { return }
        let newRun = SlimRun(
            startedAt: Date(),
            preset: preset,
            mode: mode,
            chunkSize: chunkSize,
            items: plan.items
        )
        do { try SlimRunStore.writePlan(newRun) } catch { stopForSafety(error); return }
        run = newRun
        albumIndex = [:]  // stale index from a previous run would drop album membership
        resume()
    }

    func resume() {
        guard run != nil, !isRunning, !isPausing, !isRecovering else { return }
        if case .paused(reason: .safetyStop) = phase { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            phase = .denied(PHPhotoLibrary.authorizationStatus(for: .readWrite)); return
        }
        phase = .running
        // Chain onto any previous loop task. Cancellation is cooperative — an old loop
        // may still be finishing its in-flight item — and two loops writing the same run
        // would interleave and corrupt state.
        let previous = task
        task = Task {
            previous?.cancel()
            await previous?.value
            guard !Task.isCancelled, acquireOperation() else { return }
            phase = .running
            beginRunEnvironment()
            await loop()
        }
    }

    /// Stop at a clean boundary and retain both sides. Pause never starts a deletion.
    func pause() {
        guard let running = task, !isPausing else { return }
        isPausing = true
        running.cancel()
        task = Task {
            await running.value
            await stopAfterLoop(reason: .userPaused)
        }
    }

    private func stopAfterLoop(reason: PauseReason) async {
        do { try await stopSafely(reason: reason) } catch { stopForSafety(error) }
    }

    private func stopSafely(reason: PauseReason) async throws {
        defer { isPausing = false }
        // Preserve a more specific recovery phase established while we waited.
        if case .paused = phase { endRunEnvironment(); return }
        guard let current = run else { endRunEnvironment(); phase = .idle; return }
        endRunEnvironment()
        if current.isFinished { try finish() } else { phase = .paused(reason: reason) }
    }

    /// Deletes the pending copies and keeps the originals — full rollback of the
    /// unfinished window, for a user who wants out cleanly. Shows one more system
    /// prompt (for the copies this time).
    func undoPendingWindow() async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }
        do { try await undoSafely() } catch { stopForSafety(error) }
    }

    private func undoSafely() async throws {
        // Let any zombie loop task finish its in-flight item first — same single-writer
        // rule as resume().
        task?.cancel()
        await task?.value
        guard acquireOperation() else { return }
        defer { endRunEnvironment() }

        guard var current = run else { return }
        _ = try current.reconcile()
        for item in current.items where item.state == .copied {
            guard let original = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject,
                  let sourceModified = item.sourceModifiedAt, original.modificationDate == sourceModified,
                  await PhotoLibrary.byteSize(of: original) > 0, MediaSafety.unchanged(original),
                  let copyID = item.newID,
                  let copy = PHAsset.fetchAssets(withLocalIdentifiers: [copyID], options: nil).firstObject,
                  let modified = item.copyModifiedAt, copy.modificationDate == modified,
                  let digest = item.copySHA256, await MediaFingerprint.matches(copy, expected: digest),
                  MediaSafety.unchanged(original), MediaSafety.unchanged(copy) else {
                throw CompressError.sourceChanged
            }
        }
        let copyIDs = current.items.filter { $0.state == .copied }.compactMap(\.newID)

        if !copyIDs.isEmpty {
            switch await Compressor.deleteMany(copyIDs) {
            case .deleted:
                for i in current.items.indices where current.items[i].state == .copied {
                    try current.record(i, .pending)
                }

            case .partial(let goneCopies):
                // Roll back ONLY the items whose copy is confirmed gone. The rest are
                // still duplicated and must stay tracked as .copied — resetting them
                // too (or clearing the store) would orphan surviving copies.
                for i in current.items.indices where current.items[i].state == .copied {
                    guard let copyID = current.items[i].newID, goneCopies.contains(copyID) else { continue }
                    try current.record(i, .pending)
                }
                let report = try current.reconcile()
                run = current
                phase = .resumePrompt(report)
                return

            case .cancelled, .unknown:
                // The duplicate window still exists. Clearing the record here would
                // orphan the copies with nothing tracking them, and a future run would
                // list original + copy as separate items and compress both. Keep the
                // record and put the choice back on screen.
                let report = try current.reconcile()
                run = current
                phase = .resumePrompt(report)
                return
            }
        }
        try SlimRunStore.clear()
        run = nil
        endRunEnvironment()
        phase = .idle
    }

    /// Explicitly abandon bookkeeping only: preserve every original and every copy.
    func keepAllAndEndRun() async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }
        task?.cancel()
        await task?.value
        do { try SlimRunStore.clear() } catch { stopForSafety(error); return }
        run = nil
        endRunEnvironment()
        phase = .done(summary: "All remaining originals and copies were kept. Review any duplicates in Photos before starting another run.")
    }

    // MARK: Loop

    private func loop() async {
        do { try await loopSafely() }
        catch is CancellationError { /* The pause task owns cleanup after the loop exits. */ }
        catch { stopForSafety(error) }
    }

    private func loopSafely() async throws {
        guard var current = run else { return }
        defer { if SlimRunStore.hasRun { run = current } }
        _ = try current.reconcile()

        // Failures are frequently transient (iCloud fetch, interrupted export), so each
        // session gives them another chance instead of freezing them out of the run —
        // genuinely incompressible items just fail fast again.
        for i in current.items.indices where current.items[i].state == .failedKept {
            try current.record(i, .pending)
        }
        current.recomputeTotals()

        total = current.items.count
        processed = current.items.count { $0.state != .pending }
        savedBytes = current.savedBytes
        pendingDeletes = current.pendingDeleteIDs.count
        sessionBaseProcessed = processed  // ETA throughput is per-session, see eta
        startedAt = Date()

        // Clear any duplicate window left by a previous stop BEFORE creating anything
        // new — and this is what makes the resume screen's "Finish cleanup" immediate
        // rather than deferred to the next flush threshold.
        if !current.pendingDeleteIDs.isEmpty {
            let flushed = try await performFlush(&current)
            run = current
            guard flushed else { return }
            if current.isFinished { try finish(); return }
        }

        // One album walk for the whole run — per item it would be O(n²) and take days.
        if albumIndex.isEmpty {
            let ids = current.items.map(\.id)
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var assets: [PHAsset] = []
            fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
            albumIndex = Compressor.userAlbumIndex(for: assets)
        }

        var sinceChunkStart = 0

        for index in current.items.indices {
            if Task.isCancelled { break }
            guard current.items[index].state == .pending else { continue }
            let item = current.items[index]

            // Per-item headroom, checked BEFORE the item: an iCloud original may need
            // downloading (~item.bytes) plus its copy written (≤ item.bytes) while the
            // trashed originals free nothing — a 4 GB video on a nearly-full phone must
            // pause here, not die mid-download and get branded a permanent failure.
            if !StorageSafety.hasHeadroom(free: Compressor.availableBytes(), bytes: item.bytes) {
                run = current
                endRunEnvironment()
                phase = .paused(reason: .lowSpace)
                return
            }

            currentAsset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject
            itemProgress = nil

            let outcome = await SlimEngine.processOne(
                item,
                preset: current.preset,
                albums: albumIndex[item.id] ?? [],
                onProgress: { [weak self] fraction in self?.itemProgress = fraction }
            )

            switch outcome {
            case .copied(let newID, let saved, let modifiedAt, let digest):
                // Durability point: the log must know a copy exists before we could ever
                // delete its original.
                try current.record(index, .copied, newID: newID, savedBytes: saved, copyModifiedAt: modifiedAt, copySHA256: digest)
                pendingDeletes += 1
            case .failed:
                try current.record(index, .failedKept)
            case .vanished, .notOnDevice:
                try current.record(index, .skipped)
            }

            processed += 1
            sinceChunkStart += 1

            // Never flush from a cancelled loop: the pause/background handler owns the
            // stop sequence, and a flush racing it would show a prompt the paused UI
            // doesn't know about.
            if pendingDeletes >= SlimEngine.deleteFlushSize, !Task.isCancelled {
                let result = try await performFlush(&current)
                run = current
                guard result else { return }   // stopped; phase already set
            }

            // Chunked mode: hand back so the user can empty Recently Deleted and actually
            // reclaim the space. A declined flush wins over the chunk pause — the user
            // must see the duplicate-window state, not "Chunk done".
            if !Task.isCancelled, current.mode == .chunked, current.chunkSize > 0, sinceChunkStart >= current.chunkSize {
                let flushed = try await performFlush(&current)
                run = current
                guard flushed else { return }
                endRunEnvironment()
                if current.isFinished { try finish() } else { phase = .paused(reason: .chunkComplete(freedHint: savedBytes)) }
                return
            }

        }

        if Task.isCancelled { return }

        let flushed = try await performFlush(&current)
        run = current
        guard flushed else { return }
        try finish()
    }

    /// Returns false when the run must stop (user declined).
    @discardableResult
    private func performFlush(_ current: inout SlimRun) async throws -> Bool {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw CocoaError(.fileReadNoPermission)
        }
        let pending = current.items.filter { $0.state == .copied }
        for item in pending {
            guard let copyID = item.newID, copyID != item.id,
                  let original = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject,
                  let copy = PHAsset.fetchAssets(withLocalIdentifiers: [copyID], options: nil).firstObject,
                  let modified = item.sourceModifiedAt, original.modificationDate == modified,
                  MediaSafety.resource(for: original) != nil,
                  copy.mediaType == original.mediaType,
                  let copyModified = item.copyModifiedAt, copy.modificationDate == copyModified,
                  let digest = item.copySHA256, await MediaFingerprint.matches(copy, expected: digest),
                  MediaSafety.unchanged(original), MediaSafety.unchanged(copy) else { throw CompressError.sourceChanged }
        }
        // Cancellation during verification must not open a new system delete prompt.
        try Task.checkCancellation()
        let ids = current.pendingDeleteIDs
        guard !ids.isEmpty else { return true }

        let indexByID = Dictionary(
            current.items.indices.map { (current.items[$0].id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        switch await Compressor.deleteMany(ids) {
        case .deleted(let gone):
            for id in gone {
                guard let i = indexByID[id] else { continue }
                try current.record(i, .done)
            }
            current.recomputeTotals()
            // Derive from state, never accumulate — an accumulator double-counts if a
            // flush ever repeats (e.g. after a .unknown retry).
            savedBytes = current.savedBytes
            pendingDeletes = current.pendingDeleteIDs.count
            return true

        case .partial(let gone):
            // Some originals were removed, some weren't (hang or mid-transaction error).
            // Record what's confirmed, then stop exactly like .unknown — running ahead
            // would stack prompts on top of an unresolved transaction, and the stragglers
            // get retried by the resume flush.
            for id in gone {
                guard let i = indexByID[id] else { continue }
                try current.record(i, .done)
            }
            current.recomputeTotals()
            savedBytes = current.savedBytes
            pendingDeletes = current.pendingDeleteIDs.count
            run = current
            endRunEnvironment()
            phase = .paused(reason: .deleteStalled)
            return false

        case .cancelled:
            // Don't keep stacking copies on top of an unresolved duplicate window.
            run = current
            endRunEnvironment()
            phase = .paused(reason: .declined)
            return false

        case .unknown:
            // No successful PhotoKit verdict. Items stay .copied, never assumed deleted.
            // Stop rather than run ahead: continuing would eventually stack a SECOND
            // prompt on top of an unanswered first one. Resume flushes first, so if the
            // delete actually landed meanwhile, it self-heals without asking again.
            run = current
            endRunEnvironment()
            phase = .paused(reason: .deleteStalled)
            return false
        }
    }

    private func finish() throws {
        endRunEnvironment()
        guard let current = run else { phase = .idle; return }

        var summary = current.doneCount > 0
            ? "Slimmed \(current.doneCount) items and saved \(formatBytes(current.savedBytes))."
            : "Nothing was compressed."
        if current.failedCount > 0 {
            summary += " \(current.failedCount) couldn't be processed and were left as they were."
        }
        let skipped = current.items.count { $0.state == .skipped }
        if skipped > 0 {
            summary += " \(skipped) were skipped — stored only in iCloud (or deleted during the run) — and were left untouched."
        }
        summary += "\n\nReview saved copies before permanently deleting only their verified originals from Recently Deleted. Deletion syncs through iCloud Photos."

        try SlimRunStore.clear()
        run = nil
        phase = .done(summary: summary)
    }

    // MARK: Environment

    private func acquireOperation() -> Bool {
        if operationToken != nil { return true }
        operationToken = MediaOperation.acquire()
        if operationToken == nil { safetyMessage = "Finish the other compression or review first."; phase = .paused(reason: .safetyStop) }
        return operationToken != nil
    }

    private func beginRunEnvironment() {
        // Thousands of creates/deletes would otherwise make both list tabs rescan on loop.
        PhotoLibrary.suppressRescans = true
        // Foreground-only run: iOS gives us no meaningful background time, so the screen
        // has to stay awake or the run stalls the moment it dims.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func endRunEnvironment() {
        MediaOperation.release(operationToken)
        operationToken = nil
        if PhotoLibrary.suppressRescans {
            PhotoLibrary.suppressRescans = false
            // Every change notification during the run was discarded, so the list tabs
            // are stale — tell them to reconcile once, silently, the same way
            // resumeObserving() closes out a per-tab bulk run.
            NotificationCenter.default.post(name: .slimRunEnded, object: nil)
        }
        UIApplication.shared.isIdleTimerDisabled = false
        currentAsset = nil
        itemProgress = nil
    }

    /// Backgrounded mid-run: stop cleanly and let the checkpoint carry us. Nothing useful
    /// happens in ~30s of background time, and a half-finished transaction is worse than
    /// a resumable pause.
    ///
    /// The task reference is deliberately KEPT: the loop only observes cancellation
    /// between items, and resume() chains onto whatever is stored here — nil it and a
    /// later Continue would start a second loop concurrently with the still-finishing
    /// zombie, interleaving writes on the same run.
    func handleBackground() {
        guard isRunning, !isPausing else { return }
        // Retain the writer lock until PhotoKit acknowledges any in-flight change.
        pause()
    }
}
