import SwiftUI
import Photos

struct CompareView: View {
    /// `true` if the originals were deleted.
    let onFinish: (Bool) -> Void

    // Bound to the parent so the slider's tuned URLs/sizes are the single source of
    // truth — the parent discards exactly the files that are live here.
    @Binding var results: [CompressedResult]
    @State private var selectedID: String
    @State private var isWorking = false
    @State private var errorMessage: String?
    // IDs already saved to the library, so a retry after a mid-batch failure doesn't
    // save the same copy twice.
    @State private var savedIDs = Set<String>()

    init(results: Binding<[CompressedResult]>, onFinish: @escaping (Bool) -> Void) {
        _results = results
        _selectedID = State(initialValue: results.wrappedValue.first?.id ?? "")
        self.onFinish = onFinish
    }

    private var totalSaved: Int64 { results.reduce(0) { $0 + $1.savedBytes } }
    private var title: String {
        guard results.count > 1,
              let i = results.firstIndex(where: { $0.id == selectedID }) else { return "Compare" }
        return "\(i + 1) of \(results.count)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selectedID) {
                    ForEach($results) { $result in
                        ComparePage(result: $result).tag(result.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: results.count > 1 ? .automatic : .never))

                footer
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Dismiss without saving — nothing was written to the library yet.
                    Button("Cancel") { onFinish(false) }
                        .disabled(isWorking)
                }
            }
        }
        // Swipe-to-dismiss also discards (only while not mid-save).
        .interactiveDismissDisabled(isWorking)
        .alert("Heads up", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text(totalSaved > 0
                 ? "Saves \(formatBytes(totalSaved)) across \(results.count) photo\(results.count == 1 ? "" : "s")"
                 : "No space saved at this quality — lower it to save more")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 12) {
                Button("Keep Both") {
                    Task { await finish(deleteOriginals: false) }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button("Delete Originals") {
                    Task { await finish(deleteOriginals: true) }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .disabled(isWorking)

            Text("Compressed copies are saved to your library only when you choose above.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }

    /// Saves every compressed copy to the library now, then optionally deletes the
    /// originals. Nothing was written to the library before this point.
    private func finish(deleteOriginals: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            for result in results where !savedIDs.contains(result.id) {
                _ = try await Compressor.save(result)
                savedIDs.insert(result.id)  // don't re-save on a retry
            }
            if deleteOriginals {
                // Cancelling the system delete sheet throws — copies are already saved,
                // so the originals simply stay. Report that rather than treating it as a
                // total failure.
                do {
                    try await Compressor.deleteOriginals(results.map(\.original))
                    onFinish(true)
                } catch {
                    errorMessage = "Copies were saved, but the originals were kept."
                    onFinish(false)
                }
            } else {
                onFinish(false)
            }
        } catch {
            errorMessage = "Couldn't save the compressed copies to your library."
        }
    }
}

private struct ComparePage: View {
    @Binding var result: CompressedResult

    @State private var original: UIImage?
    @State private var compressed: UIImage?
    @State private var split: CGFloat = 0.5

    // Live quality slider. Changing it re-encodes the "after" side, debounced.
    @State private var quality: Double
    @State private var isReencoding = false
    @State private var reencodeTask: Task<Void, Never>?

    // Zoom + pan, applied to both layers together so the A/B stays pixel-aligned.
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private var scale: CGFloat { max(1, zoom * pinch) }

    /// Quality slider range. Default sits at the low (most-compressed) end so the
    /// user starts from the biggest saving and dials quality up only if needed.
    private static let qualityRange = 0.2...0.9

    init(result: Binding<CompressedResult>) {
        _result = result
        _quality = State(initialValue: Self.qualityRange.lowerBound)
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    if let compressed {
                        Image(uiImage: compressed).resizable().scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    if let original {
                        Image(uiImage: original).resizable().scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width * split)
                            }
                    }
                    if original == nil || compressed == nil {
                        ProgressView().frame(width: geo.size.width, height: geo.size.height)
                    }
                    divider(in: geo.size)
                    sideLabels(in: geo.size)
                }
                .scaleEffect(scale)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(magnify.simultaneously(with: pan))
                .onTapGesture(count: 2) { resetZoom() }
            }

            sliders

            HStack {
                label("Original", formatBytes(result.originalSize))
                Spacer()
                Text("−\(Int(result.savedFraction * 100))%")
                    .font(.headline)
                    .foregroundStyle(result.savedFraction > 0 ? .green : .orange)
                Spacer()
                label("Compressed", formatBytes(result.compressedSize))
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .onChange(of: quality) { _, q in scheduleReencode(q, debounce: true) }
        .task {
            // Decode the original downscaled to preview size — a full-res UIImage of a
            // 48MP photo is pointless on a phone screen and costs huge memory per page.
            let data = result.originalData
            let maxPixel = Self.previewMaxPixel
            original = await Task.detached(priority: .userInitiated) {
                Compressor.thumbnail(from: data, maxPixel: maxPixel)
            }.value
            // Encode at the default (most-compressed) quality so the compressed side,
            // size, and saved file all match the slider. Goes through the same tracked
            // task as slider drags, so an immediate drag cancels it (no race, no wrong file).
            scheduleReencode(quality, debounce: false)
        }
    }

    /// Long-edge cap for the compare preview. Comfortably sharp under pinch-zoom while
    /// keeping decoded images small.
    private static let previewMaxPixel = 1600

    private var sliders: some View {
        VStack(spacing: 6) {
            // Compression slider — drag left for smaller/lower quality, right for larger/higher.
            HStack(spacing: 10) {
                Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                Slider(value: $quality, in: Self.qualityRange)
                Image(systemName: "photo.fill").font(.body).foregroundStyle(.secondary)
                if isReencoding {
                    ProgressView().controlSize(.mini)
                }
            }
            Text("Quality \(Int(quality * 100)) · drag to trade size for detail")
                .font(.caption2).foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            // Before/after reveal.
            HStack(spacing: 10) {
                Text("Before").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $split, in: 0...1)
                Text("After").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    /// Live re-encode. Cancels any in-flight encode so only the latest slider value is
    /// applied — the launch encode and slider drags share this one tracked task, so they
    /// can never run concurrently and race for `result.compressedURL`.
    private func scheduleReencode(_ q: Double, debounce: Bool) {
        reencodeTask?.cancel()
        reencodeTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(250)) }
            if Task.isCancelled { return }
            await applyEncode(q)
        }
    }

    /// Re-encodes at quality `q`, swaps in the new temp file, and updates the preview.
    /// Full-res encode for the real file + true size; downscaled decode for display.
    private func applyEncode(_ q: Double) async {
        isReencoding = true
        defer { isReencoding = false }  // always clears, even on the cancel path

        let data = result.originalData
        let maxPixel = Self.previewMaxPixel
        let (encoded, preview) = await Task.detached(priority: .userInitiated) { () -> ((url: URL, size: Int64)?, UIImage?) in
            guard let enc = Compressor.reencode(originalData: data, quality: q) else { return (nil, nil) }
            return (enc, Compressor.thumbnail(fromFile: enc.url, maxPixel: maxPixel))
        }.value

        // Cancelled or superseded: drop the throwaway file, don't touch shared state.
        if Task.isCancelled { encoded.map { try? FileManager.default.removeItem(at: $0.url) }; return }

        guard let encoded else { return }
        let old = result.compressedURL
        result.compressedURL = encoded.url
        result.compressedSize = encoded.size
        result.quality = q
        compressed = preview
        if old != encoded.url { try? FileManager.default.removeItem(at: old) }
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in zoom = max(1, zoom * value) }
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

    private func resetZoom() {
        withAnimation(.spring(duration: 0.25)) {
            zoom = 1
            offset = .zero
        }
    }

    private func divider(in size: CGSize) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: 2)
            .shadow(radius: 2)
            .offset(x: size.width * split - 1)
            .allowsHitTesting(false)
    }

    /// "Original" on the left of the divider, "Compressed" on the right — so it's
    /// always clear which half is which, even when they look identical.
    private func sideLabels(in size: CGSize) -> some View {
        // Hide a side's label once the divider covers most of it.
        let edge: CGFloat = 0.12, inset: CGFloat = 48
        return ZStack {
            if split > edge {
                tag("Original").position(x: inset, y: 22)
            }
            if split < 1 - edge {
                tag("Compressed").position(x: size.width - inset, y: 22)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }

    private func label(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium))
        }
    }
}
