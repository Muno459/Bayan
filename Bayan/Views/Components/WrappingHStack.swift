import SwiftUI

/// A horizontal layout that wraps content to the next line, with alignment support.
struct WrappingHStack: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)

        for (index, position) in result.positions.enumerated() {
            let lineWidth = result.lineWidths[result.lineIndices[index]]
            let maxWidth = bounds.width

            let xOffset: CGFloat
            switch alignment {
            case .trailing:
                xOffset = maxWidth - lineWidth
            case .center:
                xOffset = (maxWidth - lineWidth) / 2
            default:
                xOffset = 0
            }

            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + position.x + xOffset,
                    y: bounds.minY + position.y
                ),
                proposal: .unspecified
            )
        }
    }

    private struct ArrangeResult {
        var size: CGSize
        var positions: [CGPoint]
        var lineWidths: [CGFloat]
        var lineIndices: [Int]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var lineWidths: [CGFloat] = []
        var lineIndices: [Int] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var currentLineWidth: CGFloat = 0
        var currentLineIndex = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                lineWidths.append(max(currentLineWidth - spacing, 0))
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
                currentLineWidth = 0
                currentLineIndex += 1
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineIndices.append(currentLineIndex)
            currentX += size.width + spacing
            currentLineWidth = currentX
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, currentX - spacing)
        }

        lineWidths.append(max(currentLineWidth - spacing, 0))

        return ArrangeResult(
            size: CGSize(width: totalWidth, height: currentY + lineHeight),
            positions: positions,
            lineWidths: lineWidths,
            lineIndices: lineIndices
        )
    }
}
