import SwiftUI

// MARK: - Color Palette

enum BayanColors {
    // Primary greens — inspired by Islamic geometric art
    static let primary = Color(hex: 0x1B6B4A)
    static let primaryLight = Color(hex: 0x2D8F65)
    static let primaryDark = Color(hex: 0x0F4A32)

    // Gold accent — for highlights, word emphasis
    static let gold = Color(hex: 0xC8A951)
    static let goldLight = Color(hex: 0xE8D48B)
    static let goldSubtle = Color(hex: 0xC8A951).opacity(0.15)

    // Backgrounds
    static let background = Color(hex: 0xFAF7F2) // warm cream
    static let cardBackground = Color.white
    static let readerBackground = Color(hex: 0xFDF8F0) // warm parchment

    // Text
    static let textPrimary = Color(hex: 0x1A1A2E)
    static let textSecondary = Color(hex: 0x6B7280)
    static let textArabic = Color(hex: 0x1A1A2E)

    // Semantic
    static let mastered = Color(hex: 0x059669)
    static let learning = Color(hex: 0xD97706)
    static let introduced = Color(hex: 0x3B82F6)
    static let unseen = Color(hex: 0x9CA3AF)

    // Dark mode variants
    static let backgroundDark = Color(hex: 0x111827)
    static let cardBackgroundDark = Color(hex: 0x1F2937)
    static let readerBackgroundDark = Color(hex: 0x0F172A)
}

// MARK: - Typography

enum BayanFonts {
    // Arabic text — system Arabic with generous size
    static func arabic(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }

    static func arabicBold(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    // English body text
    static let body = Font.system(size: 16, weight: .regular, design: .default)
    static let bodyMedium = Font.system(size: 16, weight: .medium, design: .default)
    static let caption = Font.system(size: 13, weight: .regular, design: .default)
    static let captionMedium = Font.system(size: 13, weight: .medium, design: .default)

    // Headers
    static let title = Font.system(size: 24, weight: .bold, design: .rounded)
    static let subtitle = Font.system(size: 18, weight: .semibold, design: .rounded)
    static let sectionHeader = Font.system(size: 14, weight: .semibold, design: .default)
}

// MARK: - Spacing

enum BayanSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

// MARK: - Corner Radius

enum BayanRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
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
