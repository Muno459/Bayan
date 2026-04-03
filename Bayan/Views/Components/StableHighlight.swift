import SwiftUI

/// A container that visually highlights content without affecting layout size.
/// Uses scaleEffect for visual pop and explicit animation to ensure
/// clean transitions back to 1.0 scale with no residual spacing artifacts.
struct StableHighlight<Content: View, Background: View>: View {
    let isHighlighted: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let background: Background

    @State private var currentScale: CGFloat = 1.0

    var body: some View {
        content
            .scaleEffect(currentScale)
            .background(background)
            .onChange(of: isHighlighted) { _, highlighted in
                withAnimation(.easeInOut(duration: 0.12)) {
                    currentScale = highlighted ? 1.08 : 1.0
                }
            }
    }
}
