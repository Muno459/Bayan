import SwiftUI

/// A container that visually scales its content when highlighted
/// WITHOUT changing its reported size to the layout engine.
/// This prevents WrappingHStack from re-flowing text when words
/// get highlighted during audio playback.
///
/// How it works:
/// 1. The outer frame is always the unhighlighted size (fixedSize)
/// 2. The content inside scales up visually via scaleEffect
/// 3. The background draws behind at the fixed frame size
/// 4. The layout engine never sees a size change
struct StableHighlight<Content: View, Background: View>: View {
    let isHighlighted: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let background: Background

    private let highlightScale: CGFloat = 1.08

    var body: some View {
        content
            .scaleEffect(isHighlighted ? highlightScale : 1.0)
            .background(background)
            .animation(.easeInOut(duration: 0.12), value: isHighlighted)
    }
}
