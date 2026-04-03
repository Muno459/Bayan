import SwiftUI

/// Highlights a word during audio playback without affecting layout.
/// Uses only color changes and a bottom border — no scale, no size changes.
struct StableHighlight<Content: View, Background: View>: View {
    let isHighlighted: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let background: Background

    var body: some View {
        content
            .background(background)
            .overlay(alignment: .bottom) {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(BayanColors.gold)
                        .frame(height: 2.5)
                        .padding(.horizontal, 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.1), value: isHighlighted)
    }
}
