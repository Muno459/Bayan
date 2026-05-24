import SwiftUI

/// A horizontal layout that wraps content to the next line, with
/// alignment support and optional **bidi-aware per-row reversal**.
///
/// Default behaviour (`bidiAware: false`) is unchanged: children flow
/// left-to-right and wrap to a new row when they run out of width.
///
/// With `bidiAware: true`, the layout:
///   1. Walks children LTR and computes which row each child lands on.
///   2. Within each row, identifies *consecutive runs of Arabic-script
///      children* (signalled by `.layoutValue(WrappingHStack.IsArabic.self, true)`)
///      and reverses the positions inside each run.
///
/// Result for a verse rendered word-by-word:
///   - Mixed lines keep English in its natural position and only flip
///     the Arabic words that sit next to each other.
///   - Fully-Arabic lines become one big run and reverse entirely,
///     which matches native right-to-left reading.
///   - The reversal happens **per visual row**, so an Arabic run that
///     spans a wrap boundary is reversed independently on each line —
///     fixing the "I have to jump back up to the previous line to keep
///     reading" bug without losing per-word tap targets, animations,
///     decorations, or audio highlighting.
struct WrappingHStack: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 4
    /// Opt-in. When true, the layout reads each subview's `IsArabic`
    /// layout value and applies per-row Arabic-run reversal.
    var bidiAware: Bool = false

    /// LayoutValueKey for children to signal they are Arabic-script.
    /// SubstitutionWordView reads its current display mode and sets
    /// this via `.layoutValue(WrappingHStack.IsArabic.self, true)`.
    struct IsArabic: LayoutValueKey {
        static let defaultValue: Bool = false
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
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

        // First pass: LTR flow that decides which row each subview
        // belongs to. Same logic as before, just preserves enough info
        // so the (optional) second pass can do bidi rearrangement.
        var sizes: [CGSize] = []
        var rowOfIndex: [Int] = []
        var positions: [CGPoint] = []          // (x, y) for each subview
        var lineWidths: [CGFloat] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var currentLineWidth: CGFloat = 0
        var currentLineIndex = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)

            if currentX + size.width > maxWidth && currentX > 0 {
                lineWidths.append(max(currentLineWidth - spacing, 0))
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
                currentLineWidth = 0
                currentLineIndex += 1
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            rowOfIndex.append(currentLineIndex)
            currentX += size.width + spacing
            currentLineWidth = currentX
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, currentX - spacing)
        }
        lineWidths.append(max(currentLineWidth - spacing, 0))

        // Second pass (bidi only): per row, find consecutive Arabic-script
        // runs and reverse their X-positions in place. English positions
        // are not touched, so the run's left/right boundaries are
        // preserved — only the order of Arabic words inside that boundary
        // flips. This is what gives natural Arabic reading order without
        // affecting wrap behaviour or English position.
        if bidiAware {
            // Index subviews by row for an O(n) walk.
            let rowCount = (rowOfIndex.last ?? 0) + 1
            var rows: [[Int]] = Array(repeating: [], count: rowCount)
            for (i, row) in rowOfIndex.enumerated() {
                rows[row].append(i)
            }

            for indicesInRow in rows {
                // Walk the row, identifying contiguous Arabic runs.
                var runStart: Int? = nil
                func flushRun(at endExclusive: Int) {
                    guard let start = runStart else { return }
                    let run = Array(indicesInRow[start..<endExclusive])
                    if run.count >= 2 {
                        reversePositions(of: run, sizes: sizes, positions: &positions)
                    }
                    runStart = nil
                }
                for (pos, subviewIdx) in indicesInRow.enumerated() {
                    let isArabic = subviews[subviewIdx][IsArabic.self]
                    if isArabic {
                        if runStart == nil { runStart = pos }
                    } else {
                        flushRun(at: pos)
                    }
                }
                flushRun(at: indicesInRow.count)
            }
        }

        return ArrangeResult(
            size: CGSize(width: totalWidth, height: currentY + lineHeight),
            positions: positions,
            lineWidths: lineWidths,
            lineIndices: rowOfIndex
        )
    }

    /// Given a contiguous run of subview indices that already have
    /// left-to-right positions, rewrite their X coordinates so the run
    /// renders right-to-left within the same horizontal slice. Widths
    /// + spacing are preserved; only x positions change.
    private func reversePositions(
        of indices: [Int],
        sizes: [CGSize],
        positions: inout [CGPoint]
    ) {
        guard let first = indices.first else { return }
        // Anchor: leftmost x of the run.
        let anchorX = positions[first].x
        let y = positions[first].y
        // Walk the run in REVERSED order, emitting positions starting
        // at the anchor and advancing by each word's width + spacing.
        var cursor = anchorX
        for idx in indices.reversed() {
            positions[idx] = CGPoint(x: cursor, y: y)
            cursor += sizes[idx].width + spacing
        }
    }
}
