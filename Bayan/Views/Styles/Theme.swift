import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Color Palette

enum BayanColors {
    // Primary
    static let primary = Color(hex: 0x1B6B4A)

    // Gold accent
    static let gold = Color(hex: 0xC8A951)

    // Backgrounds — adaptive for dark mode
    static let background = Color(UIColor.systemGroupedBackground)
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)
    static let readerBackground = Color(UIColor.systemBackground)

    // Text — adaptive for dark mode
    static let textPrimary = Color(UIColor.label)
    static let textSecondary = Color(UIColor.secondaryLabel)
    static let textArabic = Color(UIColor.label)

    // Semantic
    static let mastered = Color(hex: 0x059669)
    static let learning = Color(hex: 0xD97706)
    static let introduced = Color(hex: 0x3B82F6)
    static let unseen = Color(hex: 0x9CA3AF)

    // Legacy aliases
    static let backgroundDark = background
    static let cardBackgroundDark = cardBackground
    static let readerBackgroundDark = readerBackground
}

// MARK: - Typography

enum BayanFonts {
    /// Arabic font — uses system default which has proper Arabic ligature support.
    /// Do NOT use .serif design — it breaks Uthmani ligatures like لَا
    static func arabic(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular)
    }

    static let body = Font.system(size: 16, weight: .regular, design: .default)
    static let bodyMedium = Font.system(size: 16, weight: .medium, design: .default)
    static let caption = Font.system(size: 13, weight: .regular, design: .default)
}

// MARK: - Spacing

enum BayanSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

// MARK: - Corner Radius

enum BayanRadius {
    static let md: CGFloat = 12
}

// MARK: - Color Hex Init

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

// MARK: - View Modifiers

struct BayanCardStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: BayanRadius.md)
                    .fill(colorScheme == .dark ? BayanColors.cardBackgroundDark : BayanColors.cardBackground)
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
            )
    }
}

extension View {
    func bayanCard() -> some View {
        modifier(BayanCardStyle())
    }
}
