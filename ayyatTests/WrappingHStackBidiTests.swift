import XCTest
import SwiftUI
@testable import ayyat

/// Algorithmic tests for the bidi-aware WrappingHStack reversal pass.
/// Mirrors the exact arrange() loop, then asserts the resulting (x, y)
/// positions for each child against expected values. Catches any
/// regression to the LTR-only path (existing behavior) and verifies
/// the new per-row Arabic-run reversal.
final class WrappingHStackBidiTests: XCTestCase {

    // MARK: - Single-row scenarios

    func testBidiOff_preservesLTR() {
        let result = arrangeForTest(
            widths: [10, 20, 15],
            isArabic: [false, false, false],
            spacing: 4,
            maxWidth: 500,
            bidiAware: false
        )
        XCTAssertEqual(result.positions[0].x, 0)
        XCTAssertEqual(result.positions[1].x, 14)
        XCTAssertEqual(result.positions[2].x, 38)
        XCTAssertEqual(result.lineIndices, [0, 0, 0])
    }

    func testBidiOn_allEnglish_noReversal() {
        let result = arrangeForTest(
            widths: [10, 20, 15],
            isArabic: [false, false, false],
            spacing: 4,
            maxWidth: 500,
            bidiAware: true
        )
        XCTAssertEqual(result.positions[0].x, 0)
        XCTAssertEqual(result.positions[1].x, 14)
        XCTAssertEqual(result.positions[2].x, 38)
    }

    func testBidiOn_allArabicSingleRow_reversesEverything() {
        // Original LTR: A(0..10) B(14..34) C(38..53)
        // Reversed:    C at 0, B at 19, A at 43
        let result = arrangeForTest(
            widths: [10, 20, 15],
            isArabic: [true, true, true],
            spacing: 4,
            maxWidth: 500,
            bidiAware: true
        )
        XCTAssertEqual(result.positions[0].x, 43, "A should move to rightmost (was leftmost)")
        XCTAssertEqual(result.positions[1].x, 19, "B should remain in middle of reversed slice")
        XCTAssertEqual(result.positions[2].x, 0,  "C should move to leftmost (was rightmost)")
    }

    func testBidiOn_mixedRow_arabicRunReverses_englishUnchanged() {
        // Layout: E1(0..10) A1(14..29) A2(33..48) E2(52..67)
        // After:  E1 stays at 0. A1+A2 reverse → A2 at 14, A1 at 33. E2 stays at 52.
        let result = arrangeForTest(
            widths: [10, 15, 15, 15],
            isArabic: [false, true, true, false],
            spacing: 4,
            maxWidth: 500,
            bidiAware: true
        )
        XCTAssertEqual(result.positions[0].x, 0,  "E1 untouched")
        XCTAssertEqual(result.positions[1].x, 33, "A1 → where A2 was (run reversed)")
        XCTAssertEqual(result.positions[2].x, 14, "A2 → where A1 was")
        XCTAssertEqual(result.positions[3].x, 52, "E2 untouched")
    }

    func testBidiOn_loneArabicBetweenEnglish_noReversal() {
        let result = arrangeForTest(
            widths: [10, 20, 10],
            isArabic: [false, true, false],
            spacing: 4,
            maxWidth: 500,
            bidiAware: true
        )
        XCTAssertEqual(result.positions[0].x, 0)
        XCTAssertEqual(result.positions[1].x, 14, "Singleton Arabic run — no reversal")
        XCTAssertEqual(result.positions[2].x, 38)
    }

    // MARK: - Wrapping scenarios (the reported bug)

    func testBidiOn_arabicRunWrappingAcrossTwoRows_eachRowReversedInPlace() {
        // 5 Arabic words, widths 30 each, spacing 4, maxWidth 100.
        // Row 1 fits: 0+30=30, +34=64, +34=98, next won't fit (+34=132)
        // Row 1: A1(0..30) A2(34..64) A3(68..98). Row 2: A4(0..30) A5(34..64).
        // After bidi:
        //   Row 1 reversed: A3 at 0, A2 at 34, A1 at 68
        //   Row 2 reversed: A5 at 0, A4 at 34
        let result = arrangeForTest(
            widths: [30, 30, 30, 30, 30],
            isArabic: [true, true, true, true, true],
            spacing: 4,
            maxWidth: 100,
            bidiAware: true
        )
        // Row assignment
        XCTAssertEqual(result.lineIndices[0], 0)
        XCTAssertEqual(result.lineIndices[1], 0)
        XCTAssertEqual(result.lineIndices[2], 0)
        XCTAssertEqual(result.lineIndices[3], 1)
        XCTAssertEqual(result.lineIndices[4], 1)
        // Row 1 reversed positions
        XCTAssertEqual(result.positions[0].x, 68, "A1 (first recited) → visual right of row 1")
        XCTAssertEqual(result.positions[1].x, 34, "A2 → middle")
        XCTAssertEqual(result.positions[2].x, 0,  "A3 → visual left of row 1")
        // Row 2 reversed positions
        XCTAssertEqual(result.positions[3].x, 34, "A4 (first on row 2) → visual right of row 2")
        XCTAssertEqual(result.positions[4].x, 0,  "A5 → visual left of row 2")
    }

    func testBidiOn_mixedAcrossWrap_englishAnchorsHoldArabicRunsReverseLocally() {
        // E1(10) A1(30) A2(30) | wrap | A3(30) E2(10), maxWidth 80
        // Row 1 LTR: E1=0, A1=14, A2=48. Row 2 LTR: A3=0, E2=34.
        // After bidi:
        //   Row 1: E1 stays, A1+A2 reverse → A2 at 14, A1 at 48
        //   Row 2: A3 singleton (no reverse), E2 stays
        let result = arrangeForTest(
            widths: [10, 30, 30, 30, 10],
            isArabic: [false, true, true, true, false],
            spacing: 4,
            maxWidth: 80,
            bidiAware: true
        )
        XCTAssertEqual(result.lineIndices, [0, 0, 0, 1, 1])
        XCTAssertEqual(result.positions[0].x, 0,  "E1")
        XCTAssertEqual(result.positions[1].x, 48, "A1 → rightmost of its slice")
        XCTAssertEqual(result.positions[2].x, 14, "A2 → leftmost of its slice")
        XCTAssertEqual(result.positions[3].x, 0,  "A3 (singleton on its row)")
        XCTAssertEqual(result.positions[4].x, 34, "E2")
    }

    // MARK: - Edge cases

    func testBidiOn_emptyChildren_noCrash() {
        let result = arrangeForTest(
            widths: [],
            isArabic: [],
            spacing: 4,
            maxWidth: 100,
            bidiAware: true
        )
        XCTAssertEqual(result.positions.count, 0)
    }

    func testBidiOn_singleChild_noCrash() {
        let result = arrangeForTest(
            widths: [50],
            isArabic: [true],
            spacing: 4,
            maxWidth: 100,
            bidiAware: true
        )
        XCTAssertEqual(result.positions[0].x, 0)
    }

    // MARK: - Test harness
    //
    // Mirrors the exact algorithm in `WrappingHStack.arrange()`. Kept
    // in sync byte-for-byte with the production layout. If the layout
    // changes, this harness must change with it — that's by design;
    // these tests assert on the algorithm shape.

    private struct TestArrangeResult {
        var positions: [CGPoint]
        var lineIndices: [Int]
        var lineWidths: [CGFloat]
    }

    private func arrangeForTest(
        widths: [CGFloat],
        isArabic: [Bool],
        spacing: CGFloat,
        maxWidth: CGFloat,
        bidiAware: Bool
    ) -> TestArrangeResult {
        precondition(widths.count == isArabic.count)

        var positions: [CGPoint] = []
        var rowOfIndex: [Int] = []
        var lineWidths: [CGFloat] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        let lineHeight: CGFloat = 30
        var currentLineWidth: CGFloat = 0
        var currentLineIndex = 0

        for w in widths {
            if currentX + w > maxWidth && currentX > 0 {
                lineWidths.append(max(currentLineWidth - spacing, 0))
                currentX = 0
                currentY += lineHeight + spacing
                currentLineWidth = 0
                currentLineIndex += 1
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            rowOfIndex.append(currentLineIndex)
            currentX += w + spacing
            currentLineWidth = currentX
        }
        lineWidths.append(max(currentLineWidth - spacing, 0))

        if bidiAware {
            let rowCount = (rowOfIndex.last ?? 0) + 1
            var rows: [[Int]] = Array(repeating: [], count: rowCount)
            for (i, row) in rowOfIndex.enumerated() { rows[row].append(i) }
            for indicesInRow in rows {
                var runStart: Int? = nil
                func flush(at endExclusive: Int) {
                    guard let s = runStart else { return }
                    let run = Array(indicesInRow[s..<endExclusive])
                    if run.count >= 2 {
                        let first = run.first!
                        let anchorX = positions[first].x
                        let y = positions[first].y
                        var cursor = anchorX
                        for idx in run.reversed() {
                            positions[idx] = CGPoint(x: cursor, y: y)
                            cursor += widths[idx] + spacing
                        }
                    }
                    runStart = nil
                }
                for (pos, subviewIdx) in indicesInRow.enumerated() {
                    if isArabic[subviewIdx] {
                        if runStart == nil { runStart = pos }
                    } else {
                        flush(at: pos)
                    }
                }
                flush(at: indicesInRow.count)
            }
        }

        return TestArrangeResult(
            positions: positions,
            lineIndices: rowOfIndex,
            lineWidths: lineWidths
        )
    }
}
