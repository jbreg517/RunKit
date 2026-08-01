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
        TabView(selection: $page) {
            metricsPage.tag(0)
            controlsPage.tag(1)
        }
        .tabViewStyle(.page)
        .navigationTitle(title)
        .navigationBarBackButtonHidden(true)
        .containerBackground(RKW.background, for: .navigation)
        .onAppear {
            // Guard against re-entry: navigating back and forward must not restart
            // a run that's already going.
            if controller.phase == .idle || controller.phase == .saved {
                controller.start(item)
            }
        }
        .onChange(of: controller.phase) { _, new in
            if new == .saved { dismiss() }
        }
    }

    private var title: String {
        switch controller.phase {
        case .paused:  return "Paused"
        case .ending:  return "Saving…"
        default:       return item.activity.rawValue
        }
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
