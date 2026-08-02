import SwiftUI
import SwiftData

/// The marketing version — shown in Settings, and used for
/// `CFBundleShortVersionString`.
///
/// **Bump this only for a release you want testers or the App Store to see as a new
/// version.** Not on every commit. CI already derives the build number from the git
/// commit count, so every push gets a unique, strictly increasing build without
/// touching this line.
///
/// The old convention was +0.01 per push, which produced one marketing version per
/// commit. That made the TestFlight build list unreadable, and for an external tester
/// group it forces a fresh Beta App Review on every single push — Apple requires
/// review per version, not per build. Build numbers are the right thing to iterate
/// per commit; versions are for releases.
///
/// Shared convention across FuelKit, LiftKit and RunKit.
enum AppVersion {
    static let current = "0.54"
}

@main
struct RunKitApp: App {
    @AppStorage("appearance") private var appearance = "system"
    private let store: Store

    init() {
        store = Self.makeStore()
        SuiteNotifier.startBridging()   // deliver cross-app change signals to views
        // Activated at launch rather than on first use: a watch that woke while the
        // phone app was closed has a queued application context waiting, and the
        // session has to be live for the system to hand it over.
        WatchBridge.shared.container = store.container
        WatchBridge.shared.activate()
    }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(storeWarning: store.warning)
                .preferredColorScheme(preferredScheme)
        }
        .modelContainer(store.container)
    }

    // MARK: - Store

    struct Store {
        let container: ModelContainer
        /// Set when the saved store could not be opened. The app is then running on
        /// throwaway storage, which must not be mistaken for "no history yet".
        let warning: String?
    }

    /// RunKit's store file — in the shared App Group, but under a name only RunKit
    /// uses. **The filename must stay explicit.**
    ///
    /// `.modelContainer(for:)` with no configuration resolves its group container
    /// *automatically*, so the App Group entitlement silently put the store at
    /// `<AppGroup>/Library/Application Support/default.store`. LiftKit and FuelKit
    /// are entitled to the same group and also omitted a URL, so all three apps were
    /// opening the *same file*; each launch migrated it to that app's schema and
    /// dropped the others' tables. The container opened cleanly and every save
    /// succeeded, which is why it destroyed data with no visible error at all.
    ///
    /// It only bit on signed builds: an unsigned build has no group container, so
    /// the entitlement didn't resolve and each app quietly used its own directory.
    /// TestFlight signing is what made the App Group real.
    ///
    /// The group is kept (suite convention: one store per app, each explicitly
    /// named, so an extension could read it later) at the cost of the location
    /// depending on entitlements. `migrateBetweenLocations` copies the store across
    /// when that flips, so switching install channels doesn't strand data.
    static var storeURL: URL {
        let preferred = groupStoreURL ?? privateStoreURL
        migrateBetweenLocations(to: preferred)
        return preferred
    }

    private static let storeFilename = "RunKit.store"

    /// `<AppGroup>/Library/Application Support/RunKit.store`, or nil when the App
    /// Group isn't provisioned (unsigned builds).
    private static var groupStoreURL: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SuiteProfileStore.appGroupID)
        else { return nil }
        let directory = container.appending(path: "Library/Application Support")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: storeFilename)
    }

    private static var privateStoreURL: URL {
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: storeFilename)
    }

    /// Carry the store across when the preferred location changes — which happens
    /// whenever a build gains or loses the App Group entitlement. Copies rather than
    /// moves, so a bad outcome leaves the original intact.
    private static func migrateBetweenLocations(to preferred: URL) {
        let files = FileManager.default
        guard !files.fileExists(atPath: preferred.path) else { return }
        let alternates = [groupStoreURL, privateStoreURL]
            .compactMap { $0 }
            .filter { $0.path != preferred.path }
        guard let source = alternates.first(where: { files.fileExists(atPath: $0.path) }) else { return }
        try? files.copyItem(at: source, to: preferred)
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: source.path + suffix)
            guard files.fileExists(atPath: companion.path) else { continue }
            try? files.copyItem(at: companion,
                                to: URL(fileURLWithPath: preferred.path + suffix))
        }
    }

    /// Opens the saved store. Falls back to memory rather than crashing — a launch
    /// crash-loop is an App Review 2.1 rejection — but the fallback is **visible**,
    /// because a silent one is how a session of data goes missing without anyone
    /// noticing.
    private static func makeStore() -> Store {
        do {
            let container = try ModelContainer(
                for: ActivitySession.self, RoutePoint.self,
                CustomWorkout.self, ScheduledRun.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            StoreHealth.shared.storePath = container.configurations.first?.url.path
            SharedStoreRecovery.recoverIfNeeded(into: container)
            return Store(container: container, warning: nil)
        } catch {
            StoreHealth.shared.recordOpenFailure(error, fellBackToMemory: true)
            // The file on disk is deliberately left untouched, so a later build can
            // still recover it.
            // The full error, not `localizedDescription`: SwiftData reports migration
            // failures as an opaque "The operation couldn’t be completed", which says
            // nothing about which model or property actually broke.
            let message = """
                RunKit couldn’t open your saved history, so it is running on \
                temporary storage — anything you record now will be lost when you \
                close the app. Nothing on your device has been deleted. Please \
                export a backup if you can, then report this.

                \(String(describing: error))
                """
            if let memory = try? ModelContainer(
                for: ActivitySession.self, RoutePoint.self,
                CustomWorkout.self, ScheduledRun.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            ) {
                return Store(container: memory, warning: message)
            }
            fatalError("RunKit could not create a model container: \(error)")
        }
    }
}

struct RootTabView: View {
    let storeWarning: String?

    @Environment(\.modelContext) private var context
    @State private var router = AppRouter()
    @State private var acknowledged = false

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
        // A run whose review screen was killed before the user chose. It's already
        // in RunKit's store; this is what gets it into Apple Health, as recorded.
        // At the app root rather than in a tab, so it runs whichever tab opens.
        .task { await PendingRunCommit.sweep(context) }
        // Presented here rather than inside a tab so "Do Again" works from
        // History too, and a running session gets the full screen.
        .fullScreenCover(isPresented: $router.showActivity) {
            ActivitySessionView()
                .environment(router)
        }
        // Full screen, not a banner. A dismissible strip at the top of a TabView
        // sits under the navigation bar and gets missed — which is how a session of
        // logging into temporary storage went unnoticed in FuelKit. Losing data
        // silently is worse than an interruption.
        .fullScreenCover(isPresented: .constant(storeWarning != nil && !acknowledged)) {
            storageFailureScreen(storeWarning ?? "")
        }
    }

    private func storageFailureScreen(_ text: String) -> some View {
        ScrollView {
            VStack(spacing: RKSpacing.lg) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(RKColor.danger)
                Text("Storage problem")
                    .font(RKFont.title)
                    .foregroundColor(RKColor.textPrimary)
                Text(text)
                    .font(RKFont.body)
                    .foregroundColor(RKColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Continue without saving") { acknowledged = true }
                    .buttonStyle(RKSecondaryButtonStyle())
            }
            .padding(RKSpacing.xl)
            .frame(maxWidth: .infinity)
        }
        .background(RKColor.background.ignoresSafeArea())
    }
}
