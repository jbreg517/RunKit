import SwiftUI

@main
struct RunKitWatchApp: App {
    init() {
        // Activate before the first view appears, so the menu the system already
        // holds in `receivedApplicationContext` is adopted in time to draw the
        // first frame rather than popping in a moment later.
        WatchStore.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .task {
                    // Asked at launch, not at Start. A HealthKit permission sheet
                    // appearing over a run that has already begun costs the user the
                    // first minute of it.
                    await WatchWorkoutController.shared.requestAuthorization()
                    // Then pick up any run that outlived the app. Ordered after
                    // authorization because recovery needs HealthKit access to do
                    // anything with the session it gets back.
                    WatchWorkoutController.shared.recoverIfNeeded()
                }
        }
    }
}
