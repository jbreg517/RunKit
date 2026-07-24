import ActivityKit
import WidgetKit
import SwiftUI

private let gold = Color(red: 0.831, green: 0.659, blue: 0.263)   // #D4A843

/// Live Activity for an in-progress run — time (auto-ticking from startDate) and
/// distance on the lock screen and in the Dynamic Island.
struct RunWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            // Lock screen / banner
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.activityLabel.uppercased())
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(timerInterval: context.attributes.startDate...Date.distantFuture, countsDown: false)
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(gold)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.state.distanceText)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    if !context.state.detailText.isEmpty {
                        Text(context.state.detailText).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(gold)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(timerInterval: context.attributes.startDate...Date.distantFuture, countsDown: false)
                            .monospacedDigit().font(.title3.weight(.bold))
                    } icon: {
                        Image(systemName: "figure.run").foregroundStyle(gold)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.distanceText).font(.title3.weight(.bold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.detailText.isEmpty {
                        Text(context.state.detailText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Text(timerInterval: context.attributes.startDate...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 54)
            } compactTrailing: {
                Text(context.state.distanceText)
            } minimal: {
                Image(systemName: "figure.run").foregroundStyle(gold)
            }
            .keylineTint(gold)
        }
    }
}
