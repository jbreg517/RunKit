import SwiftUI
import SwiftData

/// Bumped +0.01 per push (shared convention with LiftKit). CI derives the build
/// number from the git commit count.
enum AppVersion {
    static let current = "0.01"
}

@main
struct RunKitApp: App {
    @AppStorage("appearance") private var appearance = "system"

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(preferredScheme)
        }
        .modelContainer(for: [ActivitySession.self, RoutePoint.self])
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "circle.dashed") }
            ActivitySessionView()
                .tabItem { Label("Activity", systemImage: "figure.run") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(RKColor.accent)
    }
}
