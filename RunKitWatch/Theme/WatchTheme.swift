import SwiftUI

/// RunKit's design tokens for the wrist.
///
/// The same palette as the phone's `RKColor`, but resolved statically to the dark
/// values: watchOS has no light appearance, so the dynamic `UIColor` provider the
/// phone uses has nothing to switch on — and `UITraitCollection` isn't available
/// here anyway. Deliberately a separate type rather than a shared one, so a change
/// to the phone's light palette can't quietly alter the watch.
enum RKW {
    static let background      = Color.black
    static let surface         = Color(hex: "#1C1C1E")
    static let surfaceElevated = Color(hex: "#2C2C2E")
    static let accent          = Color(hex: "#D4A843")
    static let success         = Color(hex: "#22C55E")
    static let danger          = Color(hex: "#EF4444")
    static let textPrimary     = Color.white
    static let textSecondary   = Color(hex: "#98989F")
    static let textMuted       = Color(hex: "#6D6D72")
    static let onAccent        = Color.black
}

/// Text styles, not fixed sizes — the watch scales type across 40–49mm cases and
/// honours the wearer's text-size setting, and a hardcoded point size fights both.
enum RKWFont {
    static let title    = Font.system(.title3,   design: .default, weight: .bold)
    static let heading  = Font.system(.headline, design: .default, weight: .semibold)
    static let body     = Font.system(.body,     design: .default, weight: .regular)
    static let bodyBold = Font.system(.body,     design: .default, weight: .semibold)
    static let caption  = Font.system(.caption2, design: .default, weight: .regular)
    /// Section headers and the "TODAY" flag — small, wide, uppercase.
    static let label    = Font.system(.caption2, design: .default, weight: .bold)
}

enum RKWSpacing {
    static let xs: CGFloat = 2
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
}

/// The gold call-to-action, matching `RKPrimaryButtonStyle` on the phone.
struct RKWPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RKWFont.bodyBold)
            .foregroundColor(RKW.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, RKWSpacing.md)
            .background(RKW.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct RKWSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RKWFont.bodyBold)
            .foregroundColor(RKW.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, RKWSpacing.md)
            .background(RKW.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Hex color
// Duplicated from the phone's `Theme.swift` rather than shared: that file imports
// UIKit for its dynamic colors and won't compile for watchOS.
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255, green: Double(g) / 255,
                  blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
