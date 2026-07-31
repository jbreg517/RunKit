import SwiftUI

/// The prebuilt library and My Workouts — same rows, one view.
///
/// Prebuilt groups by the five categories the phone already uses; saved workouts
/// arrive pre-ordered (favourites first) and stay flat, because a user's own list
/// has no categories to group by.
struct WatchWorkoutListView: View {
    let title: String
    let items: [WatchMenu.Item]
    let grouped: Bool
    let unit: UnitSystem

    var body: some View {
        List {
            if grouped {
                ForEach(categories, id: \.self) { category in
                    Section {
                        ForEach(items.filter { $0.category == category }) { row($0) }
                    } header: {
                        Text(categoryLabel(category).uppercased())
                            .font(RKWFont.label)
                            .foregroundStyle(RKW.textMuted)
                    }
                }
            } else {
                ForEach(items) { row($0) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .containerBackground(RKW.background, for: .navigation)
    }

    private func row(_ item: WatchMenu.Item) -> some View {
        NavigationLink {
            WatchStartView(item: item, unit: unit)
        } label: {
            VStack(alignment: .leading, spacing: RKWSpacing.xs) {
                Text(item.name)
                    .font(RKWFont.bodyBold)
                    .foregroundStyle(RKW.textPrimary)
                Text(item.summary(unit))
                    .font(RKWFont.caption)
                    .foregroundStyle(RKW.textSecondary)
                    .lineLimit(2)
            }
            .padding(.vertical, RKWSpacing.xs)
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RKW.surface))
    }

    /// Categories in the order the phone declares them, keeping only those that
    /// actually have items — the watch shouldn't render an empty header.
    private var categories: [String] {
        let present = Set(items.map(\.category))
        return WorkoutRecipe.Category.allCases
            .map(\.rawValue)
            .filter { present.contains($0) }
    }

    private func categoryLabel(_ raw: String) -> String {
        WorkoutRecipe.Category(rawValue: raw)?.label ?? raw
    }
}
