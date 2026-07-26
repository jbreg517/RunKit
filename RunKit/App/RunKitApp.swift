import SwiftUI
import SwiftData

/// Bumped +0.01 per push (shared convention with LiftKit). CI derives the build
/// number from the git commit count.
enum AppVersion {
    static let current = "0.46"
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
        .modelContainer(for: [ActivitySession.self, RoutePoint.self,
                              CustomWorkout.self, ScheduledRun.self])
    }
}

struct RootTabView: View {
    @State private var router = AppRouter()

    var body: some View {
        TabView(selection: $router.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "circle.dashed") }
                .tag(AppRouter.Tab.today)
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
                .tag(AppRouter.Tab.stats)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppRouter.Tab.settings)
        }
        .tint(RKColor.accent)
        .environment(router)
        // Presented here rather than inside a tab so "Do Again" works from
        // History too, and a running session gets the full screen.
        .fullScreenCover(isPresented: $router.showActivity) {
            ActivitySessionView()
                .environment(router)
        }
    }
}
