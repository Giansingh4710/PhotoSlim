import SwiftUI

@main
struct PhotoSlimApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                PhotoListView()
                    .tabItem { Label("Photos", systemImage: "photo") }
                PhotoListView(mediaType: .video)
                    .tabItem { Label("Videos", systemImage: "video") }
            }
        }
    }
}
