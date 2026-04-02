import SwiftUI

struct VerseCell: View {
    let verse: Verse
    let isCurrentVerse: Bool
    let currentWordIndex: Int?

    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(SettingsManager.self) private var settings
    @Environment(UserStore.self) private var userStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .trailing, spacing: BayanSpacing.md) {
            // Verse number + actions bar
            HStack {
                // Verse number badge
                HStack(spacing: 6) {
                    Text(verse.verseKey)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(BayanColors.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(BayanColors.primary.opacity(0.08))
                )

                Spacer()

                // Bookmark button
                Button {
                    userStore.toggleBookmark(
                        verseKey: verse.verseKey,
                        chapterId: Int(verse.verseKey.split(separator: ":").first ?? "1") ?? 1,
                        verseNumber: verse.verseNumber
                    )
                } label: {
                    Image(systemName: userStore.isBookmarked(verse.verseKey) ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 14))
                        .foregroundStyle(
                            userStore.isBookmarked(verse.verseKey)
                                ? BayanColors.gold
                                : BayanColors.textSecondary
                        )
                }
            }

            // Arabic text — full width, right-aligned, generous line spacing
            arabicTextView
                .frame(maxWidth: .infinity, alignment: .trailing)

            // Divider between Arabic and translation
            Rectangle()
                .fill(BayanColors.gold.opacity(0.2))
                .frame(height: 0.5)
                .padding(.horizontal, BayanSpacing.md)

            // Progressive substitution translation
            substitutionView
                .frame(maxWidth: .infinity, alignment: .leading)

            // Transliteration
            if settings.showTransliteration, let translitText = transliterationText, !translitText.isEmpty {
                Text(translitText)
                    .font(.system(size: settings.translationFontSize - 2, design: .serif))
                    .italic()
                    .foregroundStyle(BayanColors.textSecondary.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(3)
            }
        }
        .padding(.horizontal, BayanSpacing.md)
        .padding(.vertical, BayanSpacing.lg)
        .background(
            isCurrentVerse
                ? BayanColors.gold.opacity(0.06)
                : (colorScheme == .dark ? BayanColors.readerBackgroundDark : BayanColors.readerBackground)
        )
        .overlay(
            // Active verse indicator
            Rectangle()
                .fill(isCurrentVerse ? BayanColors.gold : .clear)
                .frame(width: 3)
                .padding(.vertical, 4),
            alignment: .leading
        )
        .animation(.easeInOut(duration: 0.25), value: isCurrentVerse)
        .animation(.easeInOut(duration: 0.15), value: currentWordIndex)

        // Separator
        Divider()
            .padding(.leading, BayanSpacing.md)
    }

    // MARK: - Arabic Text

    private var arabicTextView: some View {
        let words = verse.words?.filter { $0.isWord } ?? []
        return WrappingHStack(alignment: .trailing, spacing: 6) {
            ForEach(words) { word in
                Text(word.textUthmani ?? "")
                    .font(BayanFonts.arabic(settings.arabicFontSize))
                    .foregroundStyle(wordColor(for: word))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(wordBackground(for: word))
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .lineSpacing(settings.arabicFontSize * 0.6) // Generous spacing for diacritics
    }

    // MARK: - Progressive Substitution

    private var substitutionView: some View {
        let words = verse.words?.filter { $0.isWord } ?? []
        return WrappingHStack(alignment: .leading, spacing: 3) {
            ForEach(words) { word in
                substitutionWord(for: word)
            }
        }
    }

    @ViewBuilder
    private func substitutionWord(for word: Word) -> some View {
        let display = vocabularyStore.displayMode(for: word)
        switch display {
        case .english(let text):
            Text(text)
                .font(.system(size: settings.translationFontSize))
                .foregroundStyle(BayanColors.textPrimary)

        case .arabic(let text):
            Text(text)
                .font(BayanFonts.arabic(settings.translationFontSize + 4))
                .foregroundStyle(BayanColors.primary)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(BayanColors.primary.opacity(0.06))
                )

        case .transitioning(let arabic, let english):
            VStack(spacing: 0) {
                Text(arabic)
                    .font(BayanFonts.arabic(settings.translationFontSize + 2))
                    .foregroundStyle(BayanColors.primary)
                Text(english)
                    .font(.system(size: max(settings.translationFontSize - 3, 10)))
                    .foregroundStyle(BayanColors.textSecondary)
            }
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(BayanColors.learning.opacity(0.06))
            )
        }
    }

    // MARK: - Helpers

    private var transliterationText: String? {
        verse.words?
            .filter { $0.isWord }
            .compactMap { $0.transliteration?.text }
            .joined(separator: " ")
    }

    private func wordColor(for word: Word) -> Color {
        if let current = currentWordIndex, word.position == current {
            return BayanColors.gold
        }
        return BayanColors.textArabic
    }

    @ViewBuilder
    private func wordBackground(for word: Word) -> some View {
        if let current = currentWordIndex, word.position == current {
            RoundedRectangle(cornerRadius: 6)
                .fill(BayanColors.gold.opacity(0.15))
        }
    }
}

// MARK: - Wrapping HStack (improved FlowLayout)

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

            // Offset for alignment
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
                lineWidths.append(currentLineWidth - spacing)
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
