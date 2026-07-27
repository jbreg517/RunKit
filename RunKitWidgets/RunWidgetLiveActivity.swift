import ActivityKit
import WidgetKit
import SwiftUI

private let gold = Color(red: 0.831, green: 0.659, blue: 0.263)   // #D4A843

/// Live Activity for an in-progress run: time, distance, current pace and average
/// pace on the lock screen and in the Dynamic Island.
///
/// Time is never pushed — `Text(timerInterval:)` ticks it from `startDate` on the
/// widget's own, so the app only sends the values that need computing. Pace arrives
/// pre-formatted, because units, and pace-versus-speed on a ride, are the app's
/// decision and shouldn't be re-derived here.
struct RunWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            lockScreen(context)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(gold)
        } dynamicIsland: { context in
            island(context)
        }
    }

    // MARK: Lock screen

    private func lockScreen(_ context: ActivityViewContext<RunActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(context.attributes.activityLabel.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !context.state.detailText.isEmpty {
                    Text(context.state.detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                metric(label: "time", tint: gold) {
                    Text(timerInterval: context.attributes.startDate...Date.distantFuture,
                         countsDown: false)
                        .monospacedDigit()
                }
                metric(label: "distance") { Text(context.state.distanceText) }
                metric(label: context.state.paceLabel) { Text(context.state.paceText) }
                metric(label: "avg") { Text(context.state.avgPaceText) }
            }
        }
    }

    /// One value over its caption. Values shrink to fit so four of them survive a
    /// long pace string on a narrow phone.
    private func metric<V: View>(label: String, tint: Color = .primary,
                                 @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            value()
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Dynamic Island

    private func island(_ context: ActivityViewContext<RunActivityAttributes>) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Label {
                    Text(timerInterval: context.attributes.startDate...Date.distantFuture,
                         countsDown: false)
                        .monospacedDigit()
                        .font(.title3.weight(.bold))
                } icon: {
                    Image(systemName: "figure.run").foregroundStyle(gold)
                }
            }
            DynamicIslandExpandedRegion(.trailing) {
                Text(context.state.distanceText).font(.title3.weight(.bold))
            }
            DynamicIslandExpandedRegion(.bottom) {
                VStack(spacing: 4) {
                    HStack(spacing: 0) {
                        islandPace(context.state.paceLabel, context.state.paceText)
                        islandPace("avg \(context.state.paceLabel)", context.state.avgPaceText)
                    }
                    if !context.state.detailText.isEmpty {
                        Text(context.state.detailText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } compactLeading: {
            Text(timerInterval: context.attributes.startDate...Date.distantFuture,
                 countsDown: false)
                .monospacedDigit()
                .frame(maxWidth: 54)
        } compactTrailing: {
            // Distance stays here rather than pace: the compact island is two short
            // slots, and the number that changes every few seconds is the worse one
            // to put in a space that small.
            Text(context.state.distanceText)
        } minimal: {
            Image(systemName: "figure.run").foregroundStyle(gold)
        }
        .keylineTint(gold)
    }

    private func islandPace(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
