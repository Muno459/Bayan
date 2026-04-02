import SwiftUI

/// A verse displayed with transliteration as the PRIMARY reading text.
/// Arabic script is secondary (small, optional). The progressive substitution
/// replaces English words with transliterated Arabic as the user learns.
struct VerseCell: View {
    let verse: Verse
    let isCurrentVerse: Bool
    let currentWordIndex: Int?

    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(SettingsManager.self) private var settings
    @Environment(UserStore.self) private var userStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top bar: verse number + bookmark
            HStack {
                Text(verse.verseKey)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(BayanColors.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(BayanColors.primary.opacity(0.08)))

                Spacer()

                Button {
                    userStore.toggleBookmark(
                        verseKey: verse.verseKey,
                        chapterId: Int(verse.verseKey.split(separator: ":").first ?? "1") ?? 1,
                        verseNumber: verse.verseNumber
                    )
                } label: {
                    Image(systemName: userStore.isBookmarked(verse.verseKey) ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15))
                        .foregroundStyle(
                            userStore.isBookmarked(verse.verseKey)
                                ? BayanColors.gold : BayanColors.textSecondary
                        )
                }
            }

            // ============================================
            // PRIMARY: Transliteration line with word highlighting
            // This is what the user reads along with audio
            // ============================================
            transliterationView

            // ============================================
            // SECONDARY: Progressive substitution line
            // English words gradually become transliterated Arabic
            // ============================================
            substitutionView

            // ============================================
            // TERTIARY: Arabic script (small, optional)
            // For reference — users can toggle this in settings
            // ============================================
            if settings.showArabicScript {
                arabicScriptView
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            isCurrentVerse
                ? BayanColors.gold.opacity(0.06)
                : (colorScheme == .dark ? BayanColors.readerBackgroundDark : BayanColors.readerBackground)
        )
        .overlay(alignment: .leading) {
            if isCurrentVerse {
                Rectangle()
                    .fill(BayanColors.gold)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isCurrentVerse)
        .animation(.easeInOut(duration: 0.15), value: currentWordIndex)

        Divider().padding(.leading, 16)
    }

    // MARK: - Transliteration (PRIMARY — highlighted during audio)

    private var transliterationView: some View {
        let words = verse.words?.filter { $0.isWord } ?? []
        return WrappingHStack(alignment: .leading, spacing: 4) {
            ForEach(words) { word in
                let isHighlighted = currentWordIndex != nil && word.position == currentWordIndex
                let translit = word.transliteration?.text ?? ""

                Text(translit)
                    .font(.system(
                        size: isHighlighted ? 19 : 17,
                        weight: isHighlighted ? .bold : .medium,
                        design: .serif
                    ))
                    .foregroundStyle(isHighlighted ? BayanColors.primary : BayanColors.textPrimary)
                    .padding(.horizontal, isHighlighted ? 4 : 1)
                    .padding(.vertical, isHighlighted ? 3 : 0)
                    .background(
                        isHighlighted
                            ? RoundedRectangle(cornerRadius: 6)
                                .fill(BayanColors.primary.opacity(0.12))
                            : nil
                    )
            }
        }
        .lineSpacing(6)
    }

    // MARK: - Progressive Substitution (English → transliteration)

    private var substitutionView: some View {
        let words = verse.words?.filter { $0.isWord } ?? []
        return WrappingHStack(alignment: .leading, spacing: 3) {
            ForEach(words) { word in
                substitutionWord(for: word)
            }
        }
        .lineSpacing(4)
    }

    @ViewBuilder
    private func substitutionWord(for word: Word) -> some View {
        let display = vocabularyStore.displayMode(for: word)
        switch display {
        case .english(let text):
            // Not learned yet — plain English
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(BayanColors.textSecondary)

        case .transliteration(let text):
            // Learned — show transliteration in accent color
            Text(text)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(BayanColors.primary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(BayanColors.primary.opacity(0.07))
                )

        case .transitioning(let transliteration, let english):
            // Learning — transliteration with tiny English hint
            VStack(spacing: 0) {
                Text(transliteration)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundStyle(BayanColors.primary)
                Text(english)
                    .font(.system(size: 10))
                    .foregroundStyle(BayanColors.textSecondary.opacity(0.7))
            }
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(BayanColors.learning.opacity(0.06))
            )
        }
    }

    // MARK: - Arabic Script (TERTIARY — small, reference only)

    private var arabicScriptView: some View {
        Text(verse.textUthmani ?? "")
            .font(.system(size: 14, design: .serif))
            .foregroundStyle(BayanColors.textSecondary.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .environment(\.layoutDirection, .rightToLeft)
            .lineSpacing(4)
    }
}
