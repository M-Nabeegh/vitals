import SwiftUI

@main
struct VitalsApp: App {
    @StateObject private var client = Client()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .tint(Palette.accent)
                // The whole contract in three lines: watching the app means
                // watching the server, and nothing else does.
                .onChange(of: phase) { _, new in
                    switch new {
                    case .active: client.connect()
                    default: client.disconnect()
                    }
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            OverviewScreen()
                .tabItem { Label("Overview", systemImage: "gauge.with.dots.needle.33percent") }
            ContainersScreen()
                .tabItem { Label("Containers", systemImage: "shippingbox") }
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
