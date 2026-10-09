import SwiftUI
import AVKit
import Photos

/// Review sheet for one compressed item (photo or video). Lists the original and the
/// compressed copy — tap either to open it full-screen and compare — then Keep Both /
/// Delete Original. Nothing is written to the library until the user chooses; the
/// choice commits atomically (see Compressor.finishReview).
struct MediaReviewView: View {
    let result: CompressedResult
    /// `true` if the original was deleted.
    let onFinish: (Bool) -> Void

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var preview: MediaSource?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                rows
                Spacer()
                footer
            }
            .navigationTitle(result.isVideo ? "Review video" : "Review photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Dismiss without saving — nothing was written to the library yet.
                    Button("Cancel") { onFinish(false) }.disabled(isWorking)
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .sheet(item: $preview) { source in
            MediaPreviewSheet(title: source.reviewTitle, source: source)
        }
        .alert("Heads up", isPresented: presence($errorMessage)) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var rows: some View {
        VStack(spacing: 12) {
            row("Original", size: result.originalSize, detail: "Full quality",
                source: .asset(result.original))
            row("Compressed", size: result.compressedSize,
                detail: "Saves \(result.savedPercent)%",
                source: .file(result.compressedURL, isVideo: result.isVideo))
        }
        .padding(.horizontal)
    }

    private func row(_ label: String, size: Int64, detail: String, source: MediaSource) -> some View {
        Button { preview = source } label: {
            HStack(spacing: 14) {
                Image(systemName: result.isVideo ? "play.circle.fill" : "photo")
                    .font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.headline)
                    Text("\(formatBytes(size)) · \(detail)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text("Saves \(formatBytes(result.savedBytes)) · \(result.savedPercent)% smaller")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 12) {
                Button("Keep Both") { finish(deleteOriginal: false) }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("Delete Original") { finish(deleteOriginal: true) }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            .disabled(isWorking)

            Text("Compression can lose detail. Deletion also syncs through iCloud Photos. Originals stay in Recently Deleted for up to 30 days; review your copy before deleting them permanently. People tags and some library associations do not transfer.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }

    private func finish(deleteOriginal: Bool) {
        // .disabled(isWorking) only lands after a re-render — this guard stops a
        // double-tap from starting two concurrent saves.
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch try await Compressor.finishReview([result], deleteOriginals: deleteOriginal) {
                case .deleted: onFinish(true)
                case .kept: onFinish(false)
                case .cancelled: break  // atomic — nothing changed; stay for another decision
                }
            } catch {
                errorMessage = "Couldn't save the compressed copy to your library."
            }
        }
    }
}

/// A playable/viewable media source: a library asset (the original) or a temp file
/// (the compressed copy). Identifiable so it can drive a `.sheet(item:)`.
enum MediaSource: Identifiable {
    case asset(PHAsset)
    case file(URL, isVideo: Bool)

    var id: String {
        switch self {
        case .asset(let a): a.localIdentifier
        case .file(let url, _): url.absoluteString
        }
    }

    var isVideo: Bool {
        switch self {
        case .asset(let a): a.mediaType == .video
        case .file(_, let isVideo): isVideo
        }
    }

    var reviewTitle: String {
        switch self {
        case .asset: "Original"
        case .file: "Compressed"
        }
    }
}

/// Full-screen preview of a media source. Video plays in an AVPlayer; photo shows the
/// full-quality image. Pinch to zoom, drag to pan while zoomed. When `onCompress` is
/// set (the list-tap preview), a bottom bar offers the quality presets.
struct MediaPreviewSheet: View {
    let title: String
    let source: MediaSource
    var onCompress: ((QualityPreset) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var showPresets = false

    // Pinch to zoom, drag to pan while zoomed.
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    private var scale: CGFloat { max(1, zoom * pinch) }

    /// Long-edge cap for the photo preview — sharp under pinch-zoom without decoding a
    /// 48MP bitmap.
    private static let previewMaxPixel = 2400

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                }
                .safeAreaInset(edge: .bottom) { compressBar }
                .confirmationDialog("Choose quality", isPresented: $showPresets, titleVisibility: .visible) {
                    ForEach(QualityPreset.allCases) { preset in
                        Button(source.isVideo ? preset.videoLabel : preset.label) { onCompress?(preset) }
                    }
                } message: {
                    Text("Higher quality keeps more detail but saves less space.")
                }
                .task { await load() }
                .onDisappear { player?.pause(); player = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if source.isVideo, let player {
                VideoPlayer(player: player)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if loadFailed {
                ContentUnavailableView("Couldn't load this \(source.isVideo ? "video" : "photo")",
                                       systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .scaleEffect(scale)
        .offset(x: offset.width + drag.width, y: offset.height + drag.height)
        .simultaneousGesture(magnify)
        .simultaneousGesture(pan)
    }

    private func load() async {
        switch source {
        case .file(let url, let isVideo):
            if isVideo { player = AVPlayer(url: url); player?.play() }
            else { image = Compressor.previewImage(fromFile: url, maxPixel: Self.previewMaxPixel) }
        case .asset(let asset):
            if asset.mediaType == .video {
                if let item = await VideoCompressor.playerItem(for: asset) {
                    player = AVPlayer(playerItem: item); player?.play()
                } else { loadFailed = true }
            } else {
                image = await Compressor.previewImage(for: asset, maxPixel: Self.previewMaxPixel)
                if image == nil { loadFailed = true }
            }
        }
    }

    @ViewBuilder
    private var compressBar: some View {
        if onCompress != nil {
            Button { showPresets = true } label: {
                Text("Compress").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.bar)
        }
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                zoom = max(1, zoom * value)
                if zoom == 1 { offset = .zero }  // fully zoomed out → recenter
            }
    }

    // Panning only makes sense while zoomed in.
    private var pan: some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in
                if scale > 1 { state = value.translation }
            }
            .onEnded { value in
                if scale > 1 {
                    offset.width += value.translation.width
                    offset.height += value.translation.height
                }
            }
    }
}

/// Optional state → Bool binding: a system-initiated dismissal clears the source,
/// instead of drifting out of sync with a `.constant()`.
func presence<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
}
