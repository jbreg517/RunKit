import SwiftUI
import SwiftData

/// Bumped +0.01 per push (shared convention with LiftKit). CI derives the build
/// number from the git commit count.
enum AppVersion {
    static let current = "0.13"
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
    @State private var router = AppRouter()

    var body: some View {
        TabView(selection: $router.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "circle.dashed") }
                .tag(AppRouter.Tab.today)
            ActivitySessionView()
                .tabItem { Label("Activity", systemImage: "figure.run") }
                .tag(AppRouter.Tab.activity)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppRouter.Tab.history)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppRouter.Tab.settings)
        }
        .tint(RKColor.accent)
        .environment(router)
    }
}
