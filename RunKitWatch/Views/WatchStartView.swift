import SwiftUI

/// Confirm screen: what you're about to run, then one gold button.
///
/// A structured workout shows its cards in order. On a screen this size the list is
/// the *whole* value of the screen — you tapped a name, and this is where you find
/// out whether "Yasso 800s" is six reps or ten before you're already running.
struct WatchStartView: View {
    let item: WatchMenu.Item
    let unit: UnitSystem
    @State private var owner = RecordingOwner.shared
    /// Remembered between runs — someone who trains on a treadmill tends to keep
    /// doing it, and re-toggling before every session gets old.
    @AppStorage("watchIndoor") private var indoor = false
    /// Whether this session carries weight. **Not** remembered, unlike the pack
    /// weight itself and unlike `indoor` — attributing a pack to a run somebody did
    /// empty-handed corrupts their loaded volume, and on a watch there is no setup
    /// screen to notice it on.
    @State private var rucking = false
    /// Kilograms, mirroring the phone's `ruckWeightKg` default. Stored per-device
    /// rather than synced: the watch is often the one that knows, and a value
    /// arriving mid-run from the phone would be worse than a stale one.
    @AppStorage("watchRuckKg") private var ruckKg = 10.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RKWSpacing.lg) {
                header
                if item.segments.count > 1 { cardList }
                indoorToggle
                ruckControls
                if owner.isRemoteRecording { phoneRecordingWarning }
                startButton
            }
            .padding(.horizontal, RKWSpacing.sm)
            .padding(.bottom, RKWSpacing.lg)
        }
        .navigationTitle(item.activity.rawValue)
        .containerBackground(RKW.background, for: .navigation)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RKWSpacing.xs) {
            Text(item.name.isEmpty ? item.activity.rawValue : item.name)
                .font(RKWFont.title)
                .foregroundStyle(RKW.textPrimary)
            Text(item.summary(unit))
                .font(RKWFont.caption)
                .foregroundStyle(RKW.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardList: some View {
        VStack(spacing: RKWSpacing.sm) {
            ForEach(Array(item.segments.enumerated()), id: \.element.id) { index, segment in
                HStack(alignment: .top, spacing: RKWSpacing.md) {
                    Text("\(index + 1)")
                        .font(RKWFont.caption)
                        .foregroundStyle(RKW.accent)
                        .frame(width: 14, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(segment.label.isEmpty ? segment.activity.rawValue : segment.label)
                            .font(RKWFont.body)
                            .foregroundStyle(RKW.textPrimary)
                        Text(segment.summary(unit))
                            .font(RKWFont.caption)
                            .foregroundStyle(RKW.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(RKWSpacing.md)
                .background(RKW.surface,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// Stated, not blocked — the same call as on the phone. Blocking would depend on
    /// the two devices staying in contact, and this app exists to work without that.
    private var phoneRecordingWarning: some View {
        HStack(alignment: .top, spacing: RKWSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(RKW.accent)
            Text("Your iPhone is already recording. Starting here saves the run twice.")
                .font(RKWFont.caption)
                .foregroundStyle(RKW.textSecondary)
        }
        .padding(RKWSpacing.md)
        .background(RKW.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Indoor turns GPS off and hands distance to the watch's wrist-motion model.
    private var indoorToggle: some View {
        Toggle(isOn: $indoor) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Indoor")
                    .font(RKWFont.body)
                    .foregroundStyle(RKW.textPrimary)
                Text(indoor ? "No GPS · wrist distance" : "GPS · route recorded")
                    .font(RKWFont.caption)
                    .foregroundStyle(RKW.textMuted)
            }
        }
        .tint(RKW.accent)
    }

    /// Ruck toggle, and the weight behind it. The stepper only appears once the
    /// toggle is on — three rows of controls is already most of a watch screen, and
    /// most sessions aren't weighted.
    @ViewBuilder
    private var ruckControls: some View {
        Toggle(isOn: $rucking.animation()) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Ruck")
                    .font(RKWFont.body)
                    .foregroundStyle(RKW.textPrimary)
                Text(rucking ? "Weight recorded with the run" : "No added weight")
                    .font(RKWFont.caption)
                    .foregroundStyle(RKW.textMuted)
            }
        }
        .tint(RKW.accent)
        .onChange(of: rucking) { _, on in
            // Snap onto the step of the unit being shown, so an imperial user gets
            // 20 lb rather than 22.0 lb from a stored 10 kg.
            if on { ruckKg = (ruckKg / unit.weightStepKg).rounded() * unit.weightStepKg }
        }

        if rucking {
            // The crown drives this, which is the one input the watch is genuinely
            // good at — no keyboard, no scribble.
            Stepper(value: $ruckKg, in: 0...80, step: unit.weightStepKg) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(unit.weightString(ruckKg, digits: unit == .metric ? 1 : 0))
                        .font(RKWFont.body)
                        .foregroundStyle(RKW.accent)
                    Text("Pack weight")
                        .font(RKWFont.caption)
                        .foregroundStyle(RKW.textMuted)
                }
            }
        }
    }

    private var startButton: some View {
        NavigationLink {
            WatchSessionView(item: item, indoor: indoor, ruckKg: rucking ? ruckKg : 0)
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .buttonStyle(RKWPrimaryButtonStyle())
    }
}
