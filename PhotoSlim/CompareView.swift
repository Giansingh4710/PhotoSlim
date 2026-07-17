import SwiftUI
import Photos

struct CompareView: View {
    let results: [CompressedResult]
    /// `true` if the originals were deleted.
    let onFinish: (Bool) -> Void

    @State private var index = 0
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var totalSaved: Int64 { results.reduce(0) { $0 + $1.savedBytes } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $index) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, result in
                        ComparePage(result: result).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: results.count > 1 ? .automatic : .never))

                footer
            }
            .navigationTitle(results.count > 1 ? "\(index + 1) of \(results.count)" : "Compare")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
        .alert("Couldn't delete", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text("Saves \(formatBytes(totalSaved)) across \(results.count) photo\(results.count == 1 ? "" : "s")")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 12) {
                Button("Keep Both") { onFinish(false) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                Button("Delete Originals") {
                    Task { await deleteOriginals() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .disabled(isDeleting)

            Text("Compressed copies are already saved to your library.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }

    private func deleteOriginals() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await Compressor.deleteOriginals(results.map(\.original))
            onFinish(true)
        } catch {
            // Cancelling the system sheet lands here — copies stay, nothing lost.
            errorMessage = "The originals were kept. Your compressed copies are still saved."
        }
    }
}

private struct ComparePage: View {
    let result: CompressedResult

    @State private var original: UIImage?
    @State private var compressed: UIImage?
    @State private var split: CGFloat = 0.5

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
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        split = min(max(value.location.x / geo.size.width, 0), 1)
                    }
                )
            }

            HStack {
                label("Original", formatBytes(result.originalSize))
                Spacer()
                Text("−\(Int(result.savedFraction * 100))%")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                label("Compressed", formatBytes(result.compressedSize))
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .task {
            // Both sides come from the exact bytes we compressed — same resolution,
            // so the divider shows a true quality A/B, not thumbnail vs full-res.
            original = UIImage(data: result.originalData)
            compressed = UIImage(contentsOfFile: result.compressedURL.path)
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

    private func label(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium))
        }
    }
}
