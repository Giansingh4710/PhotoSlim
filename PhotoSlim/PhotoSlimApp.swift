import SwiftUI

@main
struct PhotoSlimApp: App {
    init() { Compressor.cleanAbandonedTemps() }
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

private struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// Owned here rather than inside the tab so a run's state survives tab switches —
    /// SwiftUI would otherwise be free to tear the view (and the in-flight run) down.
    @State private var slim = SlimEverythingModel()

    var body: some View {
        TabView {
            PhotoListView()
                .tabItem { Label("Photos", systemImage: "photo") }
            PhotoListView(mediaType: .video)
                .tabItem { Label("Videos", systemImage: "video") }
            SlimEverythingView(model: slim)
                .tabItem { Label("Slim All", systemImage: "sparkles") }
        }
        .onChange(of: scenePhase) { _, phase in
            // Only true backgrounding stops the run — iOS gives a backgrounded app ~30s,
            // nowhere near enough to finish an item safely; stop at a clean boundary and
            // let the checkpoint resume us. Must NOT trigger on .inactive: that fires for
            // every system alert, INCLUDING the delete confirmations this run itself
            // shows every 25 items — pausing on it would pause the run at its own prompts.
            if phase == .background { slim.handleBackground() }
        }
    }
}
