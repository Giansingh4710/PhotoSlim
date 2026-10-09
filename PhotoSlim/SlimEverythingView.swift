import SwiftUI
import Photos

/// The Slim All tab: walks the whole library oldest-first, replacing each item with a
/// smaller copy so Recently Added ends up in date-taken order.
///
/// This is the most destructive thing the app does, so the confirm screen states the
/// costs plainly rather than burying them — space isn't freed until the user empties
/// Recently Deleted, People/Memories don't survive, and iOS will prompt repeatedly.
struct SlimEverythingView: View {
    /// Owned by the app root so an in-flight run survives tab switches.
    @Environment(\.scenePhase) private var scenePhase
    let model: SlimEverythingModel
    @State private var preset: QualityPreset = .medium
    @State private var mode: SlimRun.Mode = .chunked
    @State private var showFinalConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle: intro
                case .denied(let status): AccessDeniedView(status: status)
                case .scanning: scanning
                case .confirm(let plan): confirm(plan)
                case .running: running
                case .paused(let reason): paused(reason)
                case .resumePrompt(let report): resumePrompt(report)
                case .done(let summary): done(summary)
                }
            }
            .disabled(model.isRecovering || model.isPausing)
            .navigationTitle("Slim All")
            .task { await model.start() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refreshAuthorization() } }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { PrivacySupportButton() } }
        }
    }

    // MARK: Idle

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Compress supported media in order", systemImage: "sparkles")
                    .font(.title2.bold())

                Text("Compressing photos one at a time normally pushes them to the top of \"Recently Added\", scrambling the order you see when picking photos in Messages, Instagram or WhatsApp.")
                    .foregroundStyle(.secondary)

                Text("This processes supported local photos and videos from oldest to newest. Items that shrink are saved in that order. Unsupported items and items that do not shrink stay untouched, so Recently Added may still contain a mix of old and new items.")
                    .foregroundStyle(.secondary)

                Divider()

                bullet("clock", "Takes hours. Keep this screen open and the app in front — iOS won't let it run in the background.")
                bullet("trash", "Originals go to Recently Deleted for 30 days. **Your space isn't freed until you remove verified originals yourself** in the Photos app.")
                bullet("person.crop.circle.badge.xmark", "People, Memories and Shared Album membership are lost on replaced items. Albums and favourites are kept.")
                bullet("arrow.clockwise", "You can pause and resume. Interrupted runs may leave both copies; review the recovery screen before continuing.")

                Button {
                    Task { await model.scan() }
                } label: {
                    Text("Get Started").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("slim-get-started")
                .padding(.top, 8)

            }
            .padding()
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        Label {
            Text(.init(text)).font(.footnote)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }

    // MARK: Scanning

    private var scanning: some View {
        VStack(spacing: 12) {
            ProgressView(value: model.scanProgress).padding(.horizontal, 40)
            Text("Scanning library…").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Confirm

    @ViewBuilder
    private func confirm(_ plan: SlimEngine.Plan) -> some View {
        let free = Compressor.availableBytes() ?? 0
        let hasHeadroom = free >= plan.totalBytes
        let shortfall = max(0, plan.totalBytes - free)
        let chunkSize = chunkSize(for: plan, free: free)
        let prompts = max(1, (plan.items.count + SlimEngine.deleteFlushSize - 1) / SlimEngine.deleteFlushSize)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(plan.items.count) items · \(formatBytes(plan.totalBytes))")
                    .font(.title3.bold())
                if plan.skippedCount > 0 {
                    Text("\(plan.skippedCount) items are skipped (Live Photos, RAW, edited originals, or shared items). These keep their current position.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Quality") {
                    Picker("Quality", selection: $preset) {
                        ForEach(QualityPreset.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text("Videos use the matching resolution tier.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                section("Space") {
                    modeCard(
                        title: "Chunked",
                        detail: "Do up to \(chunkSize) at a time. Review saved copies before removing only their verified originals from Recently Deleted.",
                        selected: mode == .chunked,
                        enabled: true
                    ) { mode = .chunked }

                    modeCard(
                        title: "All at once",
                        detail: hasHeadroom
                            ? "You have \(formatBytes(free)) free and this needs about \(formatBytes(plan.totalBytes)). Runs start to finish."
                            : "You need about \(formatBytes(shortfall)) more free space for this. Free some up, or use Chunked.",
                        selected: mode == .headroom,
                        enabled: hasHeadroom
                    ) { mode = .headroom }
                }

                section("Before you start") {
                    warn("iOS will ask you to confirm deletions about \(prompts) times during this run. That's iOS, not a bug — there's no way to pre-approve them.")
                    warn("Your storage won't drop until you open Photos and remove only verified originals from Recently Deleted. Deleted originals hold their space for 30 days.")
                    warn("This works on photos stored on this device. Items that live only in iCloud (Optimize iPhone Storage) are skipped and left untouched — nothing is downloaded.")
                    warn("Replaced items lose People/Faces tagging, Memories and Shared Album membership. There's no API to carry those over. Albums and favourites survive.")
                }

                Button(role: .destructive) {
                    showFinalConfirm = true
                } label: {
                    Text("Slim \(plan.items.count) items").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("slim-start-run")
                .disabled(plan.items.isEmpty)

                Button("Cancel") { model.cancelToIdle() }
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .alert("Replace your whole library?", isPresented: $showFinalConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Start", role: .destructive) {
                model.begin(plan: plan, preset: preset, mode: mode,
                            chunkSize: mode == .chunked ? chunkSize : 0)
            }
        } message: {
            Text("Supported local items that shrink will be replaced with lossy copies. Unsupported or unchanged items stay untouched. Deletion syncs through iCloud Photos to your other devices. Review copies before permanently deleting originals.")
        }
    }

    /// Size a chunk to what free space can actually absorb — copies accumulate while
    /// trashed originals free nothing, so half the headroom is the safe working set.
    private func chunkSize(for plan: SlimEngine.Plan, free: Int64) -> Int {
        guard !plan.items.isEmpty, plan.totalBytes > 0 else { return 100 }
        let average = max(plan.totalBytes / Int64(plan.items.count), 1)
        let fits = Int(free / average / 2)
        return max(25, min(500, fits))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func warn(_ text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func modeCard(
        title: String, detail: String, selected: Bool, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: 16) {
            Spacer()

            if let asset = model.currentAsset {
                CurrentItemThumbnail(asset: asset)
            }

            Text("\(model.processed) of \(model.total)")
                .font(.title2.bold()).monospacedDigit()

            ProgressView(value: model.total > 0 ? Double(model.processed) / Double(model.total) : 0)
                .padding(.horizontal, 40)

            if let itemProgress = model.itemProgress {
                ProgressView(value: itemProgress)
                    .frame(width: 140)
                    .tint(.secondary)
            }

            VStack(spacing: 4) {
                Text("Saved so far: \(formatBytes(model.savedBytes))")
                if model.pendingDeletes > 0 {
                    Text("\(model.pendingDeletes) originals waiting to be removed")
                        .foregroundStyle(.secondary)
                }
                if let eta = model.eta {
                    Text("About \(eta) left").foregroundStyle(.secondary)
                }
            }
            .font(.footnote)

            Spacer()

            Text("Keep this screen open. Your screen will stay awake.")
                .font(.caption2).foregroundStyle(.secondary)

            // A video export can take minutes and can't be interrupted mid-item, so
            // pausing shows feedback instead of looking hung.
            Button(model.isPausing ? "Finishing current item…" : "Pause") { model.pause() }
                .buttonStyle(.bordered)
                .disabled(model.isPausing)
                .padding(.bottom)
        }
        .padding()
    }

    // MARK: Paused

    @ViewBuilder
    private func paused(_ reason: SlimEverythingModel.PauseReason) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch reason {
                case .chunkComplete(let freed):
                    Text("Chunk done").font(.title3.bold())
                    Text("Saved \(formatBytes(freed)) so far. Those originals are in Recently Deleted and still taking up space.")
                    emptyTrashSteps

                case .lowSpace:
                    Text("Running low on space").font(.title3.bold())
                    Text("Available storage is low or could not be verified. Both copies of unfinished items are kept. Free some space before continuing.")
                    emptyTrashSteps

                case .declined:
                    Text("Deletion cancelled").font(.title3.bold())
                    Text("You declined the delete prompt, so \(model.pendingDeletes) items currently exist twice — the smaller copies are saved but the originals are still there.")
                    Text("Continue to remove them, or undo to delete the new copies and keep your originals as they were.")
                        .font(.footnote).foregroundStyle(.secondary)

                case .deleteStalled:
                    Text("Deletion didn't finish").font(.title3.bold())
                    Text("iOS didn't confirm removing the last batch of originals. Continue to try again — if they were already removed, it carries straight on without asking twice.")

                case .safetyStop:
                    Text("Stopped to protect your photos").font(.title3.bold())
                    Text(model.safetyMessage)
                    Button("Keep all photos and end this run") {
                        Task { await model.keepAllAndEndRun() }
                    }

                case .userPaused:
                    Text("Paused").font(.title3.bold())
                    // A background-kill pause can't flush first, so be honest when
                    // originals are still awaiting removal.
                    if model.pendingDeletes > 0 {
                        Text("\(model.pendingDeletes) originals are still waiting to be removed — continuing cleans them up first.")
                    } else {
                        Text("Nothing is half-done — you can pick this up whenever.")
                    }
                }

                Button {
                    model.resume()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled({ if case .safetyStop = reason { return true }; return false }())

                if case .declined = reason {
                    Button("Undo the unfinished part", role: .destructive) {
                        Task { await model.undoPendingWindow() }
                    }
                    .frame(maxWidth: .infinity)
                }

                Button("Keep all remaining photos and end this run") {
                    Task { await model.keepAllAndEndRun() }
                }
                .frame(maxWidth: .infinity)

                Button("Stop for now") { model.cancelToIdle() }
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    private var emptyTrashSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open Photos and review the new copies first. In Recently Deleted, select only originals you have verified and choose Delete. Leave unrelated photos alone.")
                .font(.footnote)
            Text("iOS doesn't let apps empty it, or even link straight to it — this part has to be you.")
                .font(.caption2).foregroundStyle(.secondary)

        }
    }

    // MARK: Resume

    private func resumePrompt(_ report: ReconcileReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Unfinished run").font(.title3.bold())

                if report.needsCleanup {
                    Text("PhotoSlim was interrupted. \(report.duplicatesPending) items exist twice right now — the smaller copies are saved, but their originals haven't been removed yet.")
                    Text("Finish the cleanup first so your library is back to normal.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("\(report.remaining) items still to go.")
                }

                if report.orphanSuspected {
                    Text("One item may have been duplicated when it stopped. Worth a glance at your most recent photos.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    model.resume()
                } label: {
                    Text(report.needsCleanup
                         ? "Finish cleanup (\(report.duplicatesPending) originals)"
                         : "Continue (\(report.remaining) left)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Undo the unfinished part", role: .destructive) {
                    Task { await model.undoPendingWindow() }
                }
                .frame(maxWidth: .infinity)

                Button("Keep all remaining photos and end this run") {
                    Task { await model.keepAllAndEndRun() }
                }
            }
            .padding()
        }
    }

    // MARK: Done

    private func done(_ summary: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48)).foregroundStyle(.green)
            Text("All done").font(.title2.bold())
            Text(summary)
                .font(.footnote).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Spacer()
            Button("Done") { model.cancelToIdle() }
                .buttonStyle(.bordered)
                .padding(.bottom)
        }
        .padding()
    }
}

/// The item being worked on right now — makes a multi-hour run feel alive and lets the
/// user watch it walk forward through their history.
private struct CurrentItemThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let date = asset.creationDate {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: asset.localIdentifier) {
            image = await Thumbnails.load(asset, size: 240)
        }
    }
}
