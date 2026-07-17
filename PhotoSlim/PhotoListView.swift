import SwiftUI
import Photos

struct PhotoListView: View {
    @State private var library = PhotoLibrary()
    @State private var selection = Set<String>()
    @State private var preset: QualityPreset = .high
    @State private var results: [CompressedResult] = []
    @State private var isCompressing = false
    @State private var compressProgress = ""
    @State private var errorMessage: String?

    // Two-way bindings: if SwiftUI dismisses the sheet/alert itself, the source
    // state is cleared instead of drifting out of sync with a .constant().
    private var sheetBinding: Binding<Bool> {
        Binding(get: { !results.isEmpty }, set: { if !$0 { discardResults() } })
    }
    private var alertBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func discardResults() {
        Compressor.discard(results)
        results = []
        selection = []
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
            .navigationTitle("PhotoSlim")
            .toolbar { toolbarContent }
            .task { await library.requestAccess() }
            // Drop selected IDs for photos a re-scan removed, so we never target stale items.
            .onChange(of: library.items) { _, items in
                let live = Set(items.map(\.id))
                selection = selection.intersection(live)
            }
        }
        .sheet(isPresented: sheetBinding) {
            CompareView(results: results) { deleted in
                if deleted { library.remove(ids: Set(results.map(\.id))) }
                Compressor.discard(results)  // temp .heic files, no longer needed
                results = []
                selection = []
            }
        }
        .alert("Couldn't compress", isPresented: alertBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay { if isCompressing { CompressingOverlay(text: compressProgress) } }
    }

    @ViewBuilder
    private var content: some View {
        if library.isScanning {
            VStack(spacing: 12) {
                ProgressView(value: library.scanProgress)
                    .padding(.horizontal, 40)
                Text("Scanning library…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if library.items.isEmpty {
            ContentUnavailableView {
                Label("Nothing to compress", systemImage: "checkmark.circle")
            } description: {
                Text("No photos larger than \(formatBytes(PhotoLibrary.sizeThreshold)).")
            } actions: {
                CoffeeLink().buttonStyle(.bordered)
            }
        } else {
            List(library.items, selection: $selection) { item in
                PhotoRow(item: item)
            }
            .environment(\.editMode, .constant(.active))
            .safeAreaInset(edge: .top) { summaryBar }
        }
    }

    private var summaryBar: some View {
        HStack {
            Text("\(library.items.count) photos · \(formatBytes(library.totalSize))")
            Spacer()
            if !selection.isEmpty {
                Text("\(selection.count) selected")
                    .foregroundStyle(.tint)
            }
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Picker("Quality", selection: $preset) {
                ForEach(QualityPreset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if selection.isEmpty {
                CoffeeLink().labelStyle(.iconOnly)
            } else {
                Button("Compress \(selection.count)") {
                    Task { await compressSelected() }
                }
                .disabled(isCompressing)
            }
        }
    }

    private func compressSelected() async {
        let targets = library.items.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }

        isCompressing = true
        defer { isCompressing = false }

        var output: [CompressedResult] = []
        var failures: [String] = []

        // ponytail: sequential — a 50MB decode x N concurrent OOMs older devices.
        // Add a semaphore of 2 if this feels slow.
        for (index, item) in targets.enumerated() {
            compressProgress = "Compressing \(index + 1) of \(targets.count)…"
            do {
                let result = try await Compressor.compress(
                    item.asset, preset: preset, listedSize: item.byteSize
                )
                _ = try await Compressor.save(result)
                output.append(result)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        if output.isEmpty {
            errorMessage = failures.first ?? "Nothing was compressed."
        } else {
            results = output
        }
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

            VStack(alignment: .leading, spacing: 4) {
                Text(formatBytes(item.byteSize))
                    .font(.headline)
                if let date = item.asset.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
        }
        .tint(.orange)
    }
}

private struct CompressingOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
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
                 ? "PhotoSlim needs access to your whole library to find your largest photos."
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
