import SwiftUI

/// Highlights a word with font size increase and gold underline.
/// Color/background changes animate. Layout changes are instant (no glitch).
struct StableHighlight<Content: View, Background: View>: View {
    let isHighlighted: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let background: Background

    var body: some View {
        content
            .background(background)
            .overlay(alignment: .bottom) {
                if isHighlighted {
                    Capsule()
                        .fill(BayanColors.gold)
                        .frame(height: 2.5)
                        .padding(.horizontal, 1)
                }
            }
    }
}
