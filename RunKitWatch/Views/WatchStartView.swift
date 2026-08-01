import SwiftUI

/// Confirm screen: what you're about to run, then one gold button.
///
/// A structured workout shows its cards in order. On a screen this size the list is
/// the *whole* value of the screen — you tapped a name, and this is where you find
/// out whether "Yasso 800s" is six reps or ten before you're already running.
struct WatchStartView: View {
    let item: WatchMenu.Item
    let unit: UnitSystem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RKWSpacing.lg) {
                header
                if item.segments.count > 1 { cardList }
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

    private var startButton: some View {
        NavigationLink {
            WatchSessionView(item: item)
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .buttonStyle(RKWPrimaryButtonStyle())
    }
}
