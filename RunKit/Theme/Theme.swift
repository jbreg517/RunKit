import SwiftUI

// MARK: - Colors
// Shared design language with LiftKit (gold accent, dark-first surfaces).
// When the suite matures these tokens move into a shared `KitUI` package.
enum RKColor {
    static let background      = dynamic(light: "#F2F2F7", dark: "#000000")
    static let surface         = dynamic(light: "#FFFFFF", dark: "#1C1C1E")
    static let surfaceElevated = dynamic(light: "#E6E6EB", dark: "#2C2C2E")
    static let accent          = dynamic(light: "#A16207", dark: "#D4A843")
    static let success         = Color(hex: "#22C55E")
    static let danger          = Color(hex: "#EF4444")
    static let textPrimary     = Color(uiColor: .label)
    static let textSecondary   = Color(UIColor.secondaryLabel)
    static let textMuted       = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .tertiaryLabel : UIColor(white: 0.42, alpha: 1.0)
    })
    static let onAccent        = Color.black

    private static func dynamic(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light))
        })
    }
}

// MARK: - Fonts (Dynamic Type text styles, like LiftKit)
enum RKFont {
    static let title    = Font.system(.title,    design: .default, weight: .heavy)
    static let heading  = Font.system(.title3,   design: .default, weight: .bold)
    static let body     = Font.system(.body,     design: .default, weight: .regular)
    static let bodyBold = Font.system(.body,     design: .default, weight: .semibold)
    static let caption  = Font.system(.caption,  design: .default, weight: .regular)
}

enum RKSpacing {
    static let xs: CGFloat =  4
    static let sm: CGFloat =  8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

enum RKRadius {
    static let small:  CGFloat =  8
    static let medium: CGFloat = 12
    static let large:  CGFloat = 16
}

// MARK: - Button style
struct RKPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RKFont.bodyBold)
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(RKSpacing.md)
            .background(RKColor.accent)
            .cornerRadius(RKRadius.medium)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension View {
    /// Caps content width and centers it (no-op on iPhone, tidy on iPad).
    func readableWidth(_ maxWidth: CGFloat = 700) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

// MARK: - Hex color
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
