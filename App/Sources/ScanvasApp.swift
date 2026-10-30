import SwiftUI

@main
struct ScanvasApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .tint(Color.accentColor)
        }
    }
}
