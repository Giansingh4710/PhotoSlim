import SwiftUI
import Photos

struct PhotoListView: View {
    let mediaType: PHAssetMediaType
    @State private var library: PhotoLibrary
    @State private var selection = Set<String>()
    /// Selection mode: rows toggle a checkbox instead of opening the preview. Off by
    /// default so a plain tap opens the item; the toolbar "Select" toggle turns it on.
    @State private var isSelecting = false
    @State private var errorMessage: String?

    // Single-item flow: tap → preview → Compress → review the one result.
    @State private var preview: PhotoItem?
    @State private var reviewResult: CompressedResult?
    /// Set when the user picks a preset in the preview; the actual compress runs from
    /// the preview sheet's onDismiss so we never present the review sheet while the
    /// preview is still animating out (that race silently drops the review sheet).
    @State private var pendingCompress: (item: PhotoItem, preset: QualityPreset)?

    // Bulk flow: Select All → Compress → disclaimer → preset → compress+delete all.
    @State private var bulkConfirm: [PhotoItem]?
    @State private var bulkDone = 0
    @State private var bulkTotal = 0
    @State private var bulkSummary: String?
    @State private var isCompressing = false
    /// Determinate fraction (0…1) of a single-item video export; nil for photos and
    /// bulk runs, which show a spinner or the bulk bar instead.
    @State private var itemProgress: Double?

    init(mediaType: PHAssetMediaType = .image) {
        self.mediaType = mediaType
        _library = State(initialValue: PhotoLibrary(mediaType: mediaType))
    }

    private var noun: String { mediaType == .video ? "videos" : "photos" }

    /// "1 photo" / "12 videos" — one place owns the media noun and its plural.
    private func countLabel(_ n: Int) -> String {
        "\(n) \(mediaType == .video ? "video" : "photo")\(n == 1 ? "" : "s")"
    }

    var body: some View {
        NavigationStack {
            Group {
                switch library.authStatus {
                case .authorized: content
                case .notDetermined: ProgressView()
                default: AccessDeniedView(status: library.authStatus)
                }
            }
            .navigationTitle(mediaType == .video ? "Videos" : "Photos")
            .toolbar { toolbarContent }
            .task { await library.requestAccess() }
            // Drop selected IDs a re-scan removed, so we never target stale items.
            .onChange(of: library.items) { _, items in
                guard !selection.isEmpty else { return }
                selection = selection.intersection(items.map(\.id))
            }
        }
        .sheet(item: $preview, onDismiss: runPendingCompress) { item in
            MediaPreviewSheet(title: formatBytes(item.byteSize), source: .asset(item.asset)) { preset in
                // Record the choice and dismiss; the compress + review sheet run from
                // onDismiss, after this sheet is fully gone.
                pendingCompress = (item, preset)
                preview = nil
            }
        }
        .sheet(item: $reviewResult) { result in
            MediaReviewView(result: result) { deleted in
                if deleted { library.remove(ids: [result.id]) }
                Compressor.discard([result])
                reviewResult = nil
                selection = []
            }
        }
        .alert("Couldn't compress", isPresented: presence($errorMessage)) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "")
        }
        // `presenting:` hands the action closures their own copy of the targets —
        // the button must not re-read `bulkConfirm`, whose dismissal ordering vs
        // the action is unspecified.
        .confirmationDialog(
            bulkConfirm.map { dialogTitle($0.count) } ?? "",
            isPresented: presence($bulkConfirm),
            titleVisibility: .visible,
            presenting: bulkConfirm
        ) { targets in
            ForEach(QualityPreset.allCases) { preset in
                Button(mediaType == .video ? preset.videoLabel : preset.label) {
                    Task { await runBulk(targets, preset: preset) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { targets in
            Text("Higher quality keeps more detail but saves less space. This replaces \(countLabel(targets.count)) with new, smaller copies that look identical and keep their original date. Because they're new files, they'll show as \"recently added\" — near the top when you pick \(noun) in apps like Messages or WhatsApp. Originals are deleted (iOS confirms once per 100; they stay in Recently Deleted for 30 days).")
        }
        .alert("Done", isPresented: presence($bulkSummary)) {
            Button("OK") { }
        } message: {
            Text(bulkSummary ?? "")
        }
        .overlay {
            if isCompressing {
                CompressingOverlay(
                    text: overlayText,
                    progress: bulkTotal > 0 ? Double(bulkDone) / Double(bulkTotal) : itemProgress
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.isScanning {
            VStack(spacing: 12) {
                ProgressView(value: library.scanProgress).padding(.horizontal, 40)
                Text("Scanning library…").font(.footnote).foregroundStyle(.secondary)
            }
        } else if library.items.isEmpty {
            ContentUnavailableView {
                Label("Nothing to compress", systemImage: "checkmark.circle")
            } description: {
                Text("No \(noun) larger than \(formatBytes(library.threshold)). Lower the limit below.")
            } actions: {
                CoffeeLink()
            }
            .safeAreaInset(edge: .bottom) { thresholdBar }
        } else if isSelecting {
            // Selection mode: tapping a row toggles its checkbox (editMode active).
            List(library.items, selection: $selection) { item in
                PhotoRow(item: item)
            }
            .environment(\.editMode, .constant(.active))
            .safeAreaInset(edge: .top) { summaryBar }
        } else {
            // Browse mode: tapping a row opens the preview (no selection UI in the way).
            List(library.items) { item in
                Button { preview = item } label: { PhotoRow(item: item) }
                    .buttonStyle(.plain)
            }
            .safeAreaInset(edge: .top) { summaryBar }
        }
    }

    private var summaryBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(library.items.count) \(noun) · \(formatBytes(library.totalSize))")
                Spacer()
                if !selection.isEmpty {
                    Text("\(selection.count) selected").foregroundStyle(.tint)
                }
            }
            .font(.footnote)
            thresholdSlider
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var thresholdBar: some View {
        thresholdSlider
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
    }

    /// Filters the library by minimum item size. Re-scans (cheaply, from cache) on release.
    private var thresholdSlider: some View {
        HStack(spacing: 10) {
            Text("≥ \(formatBytes(library.threshold))")
                .font(.caption).monospacedDigit()
                .frame(width: 74, alignment: .leading)
            Slider(
                value: thresholdBinding,
                in: log2(Double(library.minThreshold))...log2(Double(library.maxThreshold))
            ) { editing in
                if !editing { Task { await library.rescan() } }
            }
        }
    }

    // Log scale: 500KB→50MB spans 100×, so linear would bunch everything under 5MB.
    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { log2(Double(library.threshold)) },
            set: { library.threshold = Int64(pow(2, $0)) }
        )
    }

    private var allSelected: Bool {
        !library.items.isEmpty && selection.count == library.items.count
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : Set(library.items.map(\.id))
                }
            } else if !library.items.isEmpty {
                Button("Select") { isSelecting = true }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                if selection.isEmpty {
                    Button("Done") { isSelecting = false }
                } else {
                    Button("Compress \(selection.count)") {
                        let targets = library.items.filter { selection.contains($0.id) }
                        if !targets.isEmpty { bulkConfirm = targets }
                    }
                    .disabled(isCompressing)
                }
            } else if !library.items.isEmpty {
                sortMenu
            } else {
                CoffeeLink().labelStyle(.iconOnly)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: sortBinding) {
                ForEach(SortOrder.allCases) { order in
                    Label(order.label, systemImage: order.systemImage).tag(order)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private var sortBinding: Binding<SortOrder> {
        Binding(get: { library.sortOrder }, set: { library.setSort($0) })
    }

    private var overlayText: String {
        if bulkTotal > 0 { return "Compressing \(min(bulkDone + 1, bulkTotal)) of \(bulkTotal)…" }
        return "Compressing…"
    }

    private func dialogTitle(_ count: Int) -> String {
        "Compress \(countLabel(count)) and delete the originals?"
    }

    /// Runs after the preview sheet has fully dismissed, so the review sheet it opens
    /// isn't presented on top of a still-animating dismissal.
    private func runPendingCompress() {
        guard let pending = pendingCompress else { return }
        pendingCompress = nil
        Task { await compressOne(pending.item, preset: pending.preset) }
    }

    /// Single-item flow: compress the tapped item, then open the review sheet where the
    /// user compares original vs compressed and chooses Keep Both / Delete Original.
    private func compressOne(_ item: PhotoItem, preset: QualityPreset) async {
        isCompressing = true
        // itemProgress stays nil (spinner) until the first progress callback fires. Only
        // the video export reports progress, so photos keep the spinner and videos flip
        // to a determinate bar — no media-type check needed here.
        defer { isCompressing = false; itemProgress = nil }
        do {
            reviewResult = try await Compressor.compress(
                item.asset, preset: preset, listedSize: item.byteSize
            ) { fraction in itemProgress = fraction }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Bulk flow: compress every target and, per batch of 100, save the copies and
    /// delete their originals in one atomic transaction (one iOS delete prompt per
    /// batch). Safe to interrupt — completed batches are clean, the rest untouched.
    private func runBulk(_ targets: [PhotoItem], preset: QualityPreset) async {
        // Keep the selection if we bail on low space — the warning tells the user to
        // free space and retry, so they shouldn't have to re-select everything.
        if let warning = lowSpaceWarning(for: targets) {
            bulkSummary = warning
            return
        }
        selection = []
        isSelecting = false

        isCompressing = true
        bulkTotal = targets.count
        bulkDone = 0
        library.pauseObserving()  // don't let our own batch commits trigger rescans mid-run
        defer {
            isCompressing = false
            bulkTotal = 0
            library.resumeObserving()
        }

        let outcome = await Compressor.bulkCompressAndDelete(
            targets.map { (asset: $0.asset, listedSize: $0.byteSize) },
            preset: preset,
            onProgress: { bulkDone = $0 }
        )

        library.remove(ids: outcome.deletedIDs)

        var summary = outcome.savedCount > 0
            ? "Saved \(formatBytes(outcome.savedBytes)) across \(countLabel(outcome.savedCount))."
            : "No \(noun) were compressed."
        if outcome.failures > 0 { summary += " \(outcome.failures) couldn't be compressed." }
        if outcome.cancelled {
            summary += " You stopped before the rest — those \(noun) are untouched, run it again anytime."
        } else if outcome.errored {
            summary += " Something went wrong saving to your library, so the rest were left untouched — try again."
        }
        bulkSummary = summary
    }

    /// Headroom check for a bulk run. Batches delete their originals as they go, so
    /// peak added usage is roughly one batch of copies at a time — but deleted originals
    /// sit in Recently Deleted for 30 days without freeing space, so across a full run
    /// every new copy still accumulates on top of the (trashed) originals. Bound
    /// conservatively by the total original size (copies never exceed it in aggregate
    /// for our lossy presets). Warn rather than hard-block.
    private func lowSpaceWarning(for targets: [PhotoItem]) -> String? {
        guard let free = Compressor.availableBytes() else { return nil }
        let needed = targets.reduce(0) { $0 + $1.byteSize }
        guard free < needed else { return nil }
        return "Not enough free space to do this safely. Compressing \(countLabel(targets.count)) needs about \(formatBytes(needed)) free (deleted originals stay in Recently Deleted for 30 days). Free up space or select fewer, then try again."
    }
}

private struct PhotoRow: View {
    let item: PhotoItem
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if item.asset.mediaType == .video {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.white)
                        .padding(3)
                        .shadow(radius: 1)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(formatBytes(item.byteSize)).font(.headline)
                if let date = item.asset.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { thumbnail = await Thumbnails.load(item.asset, size: 120) }
    }
}

enum Thumbnails {
    // ponytail: plain default manager — no prefetch window wired up, so
    // PHCachingImageManager bought nothing. Add start/stopCachingImages if scroll lags.
    private static let manager = PHImageManager.default()

    static func load(_ asset: PHAsset, size: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        return await withCheckedContinuation { continuation in
            var resumed = false
            manager.requestImage(
                for: asset,
                targetSize: CGSize(width: size, height: size),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // opportunistic delivers twice (thumb then full) — resume once.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

struct CoffeeLink: View {
    var body: some View {
        Link(destination: URL(string: "https://buymeacoffee.com/gians")!) {
            Label("Buy me a coffee", systemImage: "cup.and.saucer")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

private struct CompressingOverlay: View {
    let text: String
    /// Determinate fraction (0…1) for bulk runs; nil shows an indeterminate spinner.
    var progress: Double? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                if let progress {
                    ProgressView(value: progress).frame(width: 160)
                } else {
                    ProgressView()
                }
                Text(text).font(.footnote)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct AccessDeniedView: View {
    let status: PHAuthorizationStatus

    var body: some View {
        ContentUnavailableView {
            Label("Photo access needed", systemImage: "lock")
        } description: {
            Text(status == .limited
                 ? "PhotoSlim needs access to your whole library to find your largest files."
                 : "Enable photo access for PhotoSlim in Settings.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}
