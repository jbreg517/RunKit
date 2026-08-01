import SwiftUI

/// Consumes the suite activity channel (`SuiteActivityStore`) — the load LiftKit
/// (and any future app) publishes — to give RunKit light recovery awareness: if
/// you trained hard elsewhere, it nudges an easier run.
///
/// Reads other apps' feeds only (`excluding: .runkit`), so RunKit's own runs never
/// trigger it. Renders nothing until another app has published *and* the load is
/// meaningful, so it never shows an empty or preachy card. Purely advisory — it
/// changes nothing about the run itself.
struct SuiteRecoveryCard: View {
    @State private var message: String?

    var body: some View {
        Group {
            if let message {
                HStack(spacing: RKSpacing.sm) {
                    Image(systemName: "bed.double.fill")
                        .foregroundColor(RKColor.accent)
                    Text(message)
                        .font(RKFont.caption)
                        .foregroundColor(RKColor.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(RKSpacing.md)
                .background(RKColor.surface)
                .cornerRadius(RKRadius.large)
                .padding(.horizontal, RKSpacing.md)
            }
        }
        .onAppear(perform: refresh)
        // Refresh the instant a sibling app publishes (iPad multitasking), not just
        // on the next foreground.
        .onReceive(NotificationCenter.default.publisher(for: SuiteNotifier.changed)) { _ in refresh() }
    }

    private func refresh() {
        let cal = Calendar.current
        let now = Date()
        // Trained hard in another app *today* → keep this run easy.
        if let today = SuiteActivityStore.totalLoad(on: now, excluding: .runkit), today.load >= 0.5 {
            message = "You've already trained hard in another app today — keep this run easy."
            return
        }
        // Hard *yesterday* → suggest an easier or recovery effort to absorb it.
        if let y = cal.date(byAdding: .day, value: -1, to: now),
           let yesterday = SuiteActivityStore.totalLoad(on: y, excluding: .runkit),
           yesterday.load >= 0.66 {
            message = "Hard training yesterday — an easy effort today helps you recover."
            return
        }
        message = nil
    }
}
