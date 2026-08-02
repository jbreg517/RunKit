import SwiftUI

/// The live run: metrics on one page, controls on the next.
///
/// Two pages rather than one crowded screen, because the metrics page is what you
/// glance at while moving and it should hold nothing you could hit by accident. End
/// lives on the second page for the same reason.
struct WatchSessionView: View {
    let item: WatchMenu.Item
    @Environment(\.dismiss) private var dismiss
    @State private var controller = WatchWorkoutController.shared
    @State private var page = 0

    private var unit: UnitSystem { controller.unit }

    var body: some View {
        Group {
            if let summary = controller.summary {
                summaryPage(summary)
            } else if case let .failed(reason) = controller.phase {
                failedPage(reason)
            } else {
                TabView(selection: $page) {
                    metricsPage.tag(0)
                    controlsPage.tag(1)
                }
                .tabViewStyle(.page)
            }
        }
        .navigationTitle(title)
        .navigationBarBackButtonHidden(true)
        .containerBackground(RKW.background, for: .navigation)
        .onAppear {
            // Guard against re-entry: navigating back and forward must not restart
            // a run that's already going, and must not blow away a summary that
            // hasn't been read. A previous failure *should* retry.
            switch controller.phase {
            case .running, .paused, .ending, .saved: break
            case .idle, .failed:                     controller.start(item)
            }
        }
    }

    /// A workout that never started — no HealthKit, or the session was refused.
    /// Shown plainly rather than leaving the metrics page sitting at zero, which
    /// looks like a run that isn't counting.
    private func failedPage(_ reason: String) -> some View {
        VStack(spacing: RKWSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(RKW.danger)
            Text("Couldn’t start")
                .font(RKWFont.heading)
                .foregroundStyle(RKW.textPrimary)
            Text(reason)
                .font(RKWFont.caption)
                .foregroundStyle(RKW.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Back") { dismiss() }
                .buttonStyle(RKWSecondaryButtonStyle())
        }
        .padding(.horizontal, RKWSpacing.sm)
    }

    private var title: String {
        switch controller.phase {
        case .paused:  return "Paused"
        case .ending:  return "Saving…"
        case .saved:   return "Done"
        default:       return item.activity.rawValue
        }
    }

    // MARK: Summary

    /// Shown when the run is saved, instead of dropping straight back to the menu.
    /// The numbers are already gone from the live properties by then, so this reads
    /// the snapshot the controller kept.
    private func summaryPage(_ s: WatchWorkoutController.Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RKWSpacing.md) {
                Text(timeString(s.seconds))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(RKW.accent)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                HStack(alignment: .top, spacing: RKWSpacing.md) {
                    metric(unit.distanceString(s.meters), "distance")
                    metric(summaryPace(s), s.activity == .ride ? "avg speed" : "avg pace")
                }
                HStack(alignment: .top, spacing: RKWSpacing.md) {
                    metric(s.avgBpm > 0 ? "\(Int(s.avgBpm))" : "--", "avg bpm",
                           tint: s.avgBpm > 0 ? RKW.danger : RKW.textMuted)
                    metric("\(Int(s.kcal))", "kcal")
                }

                Text(syncNote)
                    .font(RKWFont.caption)
                    .foregroundStyle(RKW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Done") {
                    controller.clearSummary()
                    dismiss()
                }
                .buttonStyle(RKWPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RKWSpacing.sm)
            .padding(.bottom, RKWSpacing.lg)
        }
    }

    /// Says where the run actually is, because "saved" on a wrist with no phone in
    /// range is ambiguous — and the honest answer is that it's already safe.
    private var syncNote: String {
        "Saved to Apple Health. It’ll appear in RunKit next time your iPhone is near."
    }

    private func summaryPace(_ s: WatchWorkoutController.Summary) -> String {
        guard s.meters > 0, s.seconds > 0 else { return "--" }
        if s.activity == .ride {
            return unit.speedString(seconds: s.seconds, meters: s.meters)
        }
        return unit.paceString(seconds: s.seconds, meters: s.meters)
    }

    // MARK: Metrics

    private var metricsPage: some View {
        VStack(alignment: .leading, spacing: RKWSpacing.md) {
            if let detail = cardDetail {
                Text(detail)
                    .font(RKWFont.label)
                    .foregroundStyle(RKW.accent)
                    .lineLimit(1)
            }
            Text(timeString(controller.elapsed))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(RKW.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            HStack(alignment: .top, spacing: RKWSpacing.md) {
                metric(unit.distanceString(controller.distanceMeters), "distance")
                metric(paceText, paceLabel)
            }
            HStack(alignment: .top, spacing: RKWSpacing.md) {
                metric(controller.bpm > 0 ? "\(Int(controller.bpm))" : "--", "bpm",
                       tint: controller.bpm > 0 ? RKW.danger : RKW.textMuted)
                metric("\(Int(controller.kcal))", "kcal")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RKWSpacing.sm)
    }

    private func metric(_ value: String, _ label: String, tint: Color = RKW.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(RKWFont.caption)
                .foregroundStyle(RKW.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// On a ride the same number reads as a speed, matching the phone and the Live
    /// Activity — nobody thinks in minutes per kilometre on a bike.
    private var paceLabel: String { item.activity == .ride ? "speed" : "pace" }

    private var paceText: String {
        guard controller.phase == .running, controller.speedMps > 0.3 else { return "--" }
        if item.activity == .ride {
            return unit.speedString(metersPerSecond: controller.speedMps)
        }
        return unit.paceString(secondsPerUnit: unit.metersPerUnit / controller.speedMps)
    }

    /// The card line: which card, and what it's asking for.
    private var cardDetail: String? {
        guard let seg = controller.currentSegment else { return "WORKOUT DONE" }
        let position = controller.segments.count > 1
            ? " · \(controller.segIndex + 1)/\(controller.segments.count)" : ""
        if seg.goal == .intervals {
            return "\(controller.intPhaseIsWork ? "WORK" : "REST") · \(controller.intRep)/\(seg.reps)"
        }
        switch seg.goal {
        case .none:      return controller.segments.count > 1 ? "OPEN\(position)" : nil
        case .distance:  return "GOAL \(unit.distanceString(seg.endMeters))\(position)"
        case .time:      return "GOAL \(timeString(seg.endSeconds))\(position)"
        case .pace:      return "TARGET \(seg.paceText(unit))\(position)"
        case .heartRate: return "ZONE \(seg.hrZone)\(position)"
        case .intervals: return nil
        }
    }

    // MARK: Controls

    private var controlsPage: some View {
        VStack(spacing: RKWSpacing.md) {
            if controller.phase == .paused {
                Button {
                    controller.resume()
                    page = 0
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(RKWPrimaryButtonStyle())
            } else {
                Button {
                    controller.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(RKWSecondaryButtonStyle())
            }

            // Only meaningful with somewhere to advance to. Shown for open cards in
            // particular, which have no other way to end.
            if controller.segments.count > 1, !controller.segmentsDone {
                Button {
                    controller.next()
                } label: {
                    Label("Next Card", systemImage: "forward.end.fill")
                }
                .buttonStyle(RKWSecondaryButtonStyle())
            }

            Button(role: .destructive) {
                controller.end()
            } label: {
                Label("End", systemImage: "stop.fill")
            }
            .disabled(controller.phase == .ending)
        }
        .padding(.horizontal, RKWSpacing.sm)
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
