import SwiftUI

/// The whole menu, in one screen.
///
/// Kept deliberately short: today's suggestion, one gold Start, two quick
/// alternates, and two lists. History, stats, settings and the card builder are all
/// one tap away on a phone that's already in the room, and none of them are
/// something anyone wants to operate on a 45mm screen mid-warm-up.
struct WatchRootView: View {
    @State private var store = WatchStore.shared

    private var unit: UnitSystem { store.unit }
    private var menu: WatchMenu { store.menu }

    var body: some View {
        NavigationStack {
            List {
                if !menu.scheduledToday.isEmpty {
                    scheduledSection
                }
                startSection
                librarySection
                if !store.hasSynced {
                    unsyncedFooter
                }
            }
            // Plain, not `.carousel`: carousel's scaling animation fights the
            // custom row backgrounds and turns a five-row menu into four screens
            // of scrolling.
            .listStyle(.plain)
            .navigationTitle("RunKit")
            .containerBackground(RKW.background, for: .navigation)
        }
        .tint(RKW.accent)
    }

    // MARK: Today

    /// The suggestion. Gold-edged rather than gold-filled so it reads as *the thing
    /// you planned*, without competing with Start for the one filled accent on screen.
    private var scheduledSection: some View {
        Section {
            ForEach(menu.scheduledToday) { item in
                NavigationLink {
                    WatchStartView(item: item, unit: unit)
                } label: {
                    VStack(alignment: .leading, spacing: RKWSpacing.xs) {
                        Text("TODAY")
                            .font(RKWFont.label)
                            .foregroundStyle(RKW.accent)
                        Text(item.name)
                            .font(RKWFont.heading)
                            .foregroundStyle(RKW.textPrimary)
                        Text(item.summary(unit))
                            .font(RKWFont.caption)
                            .foregroundStyle(RKW.textSecondary)
                    }
                    .padding(.vertical, RKWSpacing.xs)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(RKW.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(RKW.accent, lineWidth: 1.5))
                )
            }
        }
    }

    // MARK: Start

    private var startSection: some View {
        Section {
            NavigationLink {
                WatchStartView(item: WatchMenu.quick(.run), unit: unit)
            } label: {
                Label("Start Run", systemImage: "figure.run")
                    .font(RKWFont.bodyBold)
                    .foregroundStyle(RKW.onAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, RKWSpacing.sm)
            }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RKW.accent))

            // Walk and Ride share a row: both are real, neither is the common case,
            // and giving each a full-width row would push the lists off screen.
            HStack(spacing: RKWSpacing.md) {
                quickTile(.walk)
                quickTile(.ride)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    private func quickTile(_ activity: ActivityType) -> some View {
        NavigationLink {
            WatchStartView(item: WatchMenu.quick(activity), unit: unit)
        } label: {
            VStack(spacing: RKWSpacing.xs) {
                Image(systemName: activity.sfSymbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(activity.rawValue)
                    .font(RKWFont.caption)
            }
            .foregroundStyle(RKW.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, RKWSpacing.md)
        }
        .buttonStyle(.plain)
        .background(RKW.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Lists

    private var librarySection: some View {
        Section {
            NavigationLink {
                WatchWorkoutListView(title: "Prebuilt", items: menu.recipes,
                                     grouped: true, unit: unit)
            } label: {
                row("Prebuilt", count: menu.recipes.count, symbol: "books.vertical.fill")
            }
            .listRowBackground(rowBackground)

            if !menu.custom.isEmpty {
                NavigationLink {
                    WatchWorkoutListView(title: "My Workouts", items: menu.custom,
                                         grouped: false, unit: unit)
                } label: {
                    row("My Workouts", count: menu.custom.count, symbol: "star.fill")
                }
                .listRowBackground(rowBackground)
            }
        } header: {
            Text("WORKOUTS")
                .font(RKWFont.label)
                .foregroundStyle(RKW.textMuted)
        }
    }

    private func row(_ title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: RKWSpacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(RKW.accent)
                .frame(width: 20)
            Text(title)
                .font(RKWFont.body)
                .foregroundStyle(RKW.textPrimary)
            Spacer(minLength: RKWSpacing.sm)
            Text("\(count)")
                .font(RKWFont.caption)
                .foregroundStyle(RKW.textMuted)
        }
        .padding(.vertical, RKWSpacing.xs)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RKW.surface)
    }

    /// Only shown before the first sync. Once a menu has arrived, an empty library
    /// means the user hasn't saved anything — telling them to open their phone then
    /// would be wrong, and Start still works regardless.
    private var unsyncedFooter: some View {
        Section {
            Text("Open RunKit on your iPhone to sync your workouts.")
                .font(RKWFont.caption)
                .foregroundStyle(RKW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
    }
}
