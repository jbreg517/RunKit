import SwiftUI

/// Browsable catalog of ready-to-run workouts (`WorkoutRecipe`). Presented as a
/// sheet from the session setup so the run-type menu stays at five entries —
/// the library adds depth without adding chrome to the main screen.
struct WorkoutLibraryView: View {
    let unit: UnitSystem
    let onPick: (WorkoutRecipe) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: WorkoutRecipe.Category = .beginner

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                categoryBar

                ScrollView {
                    LazyVStack(spacing: RKSpacing.sm) {
                        ForEach(WorkoutRecipe.inCategory(category)) { recipe in
                            card(recipe)
                        }
                    }
                    .padding(RKSpacing.md)
                }
            }
            .background(RKColor.background)
            .navigationTitle("Workouts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RKSpacing.sm) {
                ForEach(WorkoutRecipe.Category.allCases) { c in
                    let selected = c == category
                    Button {
                        category = c
                    } label: {
                        Label(c.label, systemImage: c.sfSymbol)
                            .font(RKFont.caption)
                            .padding(.horizontal, RKSpacing.sm)
                            .padding(.vertical, 7)
                            .background(selected ? RKColor.accent : RKColor.surfaceElevated)
                            .foregroundColor(selected ? RKColor.onAccent : RKColor.textPrimary)
                            .cornerRadius(RKRadius.small)
                    }
                }
            }
            .padding(.horizontal, RKSpacing.md)
            .padding(.vertical, RKSpacing.sm)
        }
    }

    private func card(_ recipe: WorkoutRecipe) -> some View {
        Button {
            onPick(recipe)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: RKSpacing.xs) {
                HStack {
                    Text(recipe.name)
                        .font(RKFont.bodyBold)
                        .foregroundColor(RKColor.textPrimary)
                    Spacer()
                    Image(systemName: recipe.workoutType.sfSymbol)
                        .foregroundColor(RKColor.accent)
                }

                Text(displaySummary(recipe))
                    .font(RKFont.body)
                    .foregroundColor(RKColor.accent)

                Text(recipe.coaching)
                    .font(RKFont.caption)
                    .foregroundColor(RKColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RKSpacing.md)
            .background(RKColor.surface)
            .cornerRadius(RKRadius.large)
        }
        .buttonStyle(.plain)
    }

    /// Distance recipes are authored in meters; show them in the user's units.
    private func displaySummary(_ r: WorkoutRecipe) -> String {
        guard r.workoutType == .distance, r.meters > 0 else { return r.summary }
        let d = unit.distance(r.meters)
        let trimmed = d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)
        return "\(trimmed) \(unit.distanceUnit) steady"
    }
}
