import Foundation
import SwiftUI

/// Favourites for the built-in `WorkoutRecipe`s.
///
/// Recipes are static data, not models, so there's nothing to set a flag on —
/// the chosen names live in `@AppStorage` instead. Saved `CustomWorkout`
/// templates carry their own `isFavorite` since they *are* models.
enum FavoriteRecipes {
    static let key = "favoriteRecipeNames"

    static func names(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    static func encode(_ names: Set<String>) -> String {
        names.sorted().joined(separator: "\n")
    }

    static func toggle(_ name: String, in raw: String) -> String {
        var set = names(raw)
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
        return encode(set)
    }

    static func contains(_ name: String, in raw: String) -> Bool {
        names(raw).contains(name)
    }

    /// Favourited recipes first, then the rest in catalogue order.
    static func sorted(_ recipes: [WorkoutRecipe], raw: String) -> [WorkoutRecipe] {
        let favs = names(raw)
        return recipes.sorted { a, b in
            let fa = favs.contains(a.name), fb = favs.contains(b.name)
            if fa != fb { return fa }
            return false
        }
    }
}

/// Tappable star used wherever something can be favourited.
struct FavoriteStar: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "star.fill" : "star")
                .foregroundColor(isOn ? RKColor.accent : RKColor.textMuted)
                .font(.system(size: 15))
                .contentShape(Rectangle())
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Remove from favourites" : "Add to favourites")
    }
}
