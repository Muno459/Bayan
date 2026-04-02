import SwiftUI

/// Verse display: progressive substitution is the PRIMARY reading text.
/// English words gradually become Arabic script as the user learns.
/// Audio word highlighting happens on the substitution line.
struct VerseCell: View {
    let verse: Verse
    let isCurrentVerse: Bool
    let currentWordIndex: Int?

    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(SettingsManager.self) private var settings
    @Environment(UserStore.self) private var userStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top bar
            HStack {
                Text(verse.verseKey)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(BayanColors.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(BayanColors.primary.opacity(0.08)))

                Spacer()

                Button {
                    Haptics.medium()
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

            // ===========================================
            // PRIMARY: Progressive substitution
            // English words become Arabic script as user learns.
            // Audio word highlighting is HERE.
            // ===========================================
            substitutionView

            // ===========================================
            // SECONDARY: Full English translation
            // ===========================================
            if settings.showTransliteration, let translation = verse.translations?.first {
                Text(translation.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    .font(.system(size: 13))
                    .foregroundStyle(BayanColors.textSecondary.opacity(0.7))
                    .lineSpacing(3)
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
                Rectangle().fill(BayanColors.gold).frame(width: 3).padding(.vertical, 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isCurrentVerse)
        .animation(.easeInOut(duration: 0.15), value: currentWordIndex)

        Divider().padding(.leading, 16)
    }

    // MARK: - Progressive Substitution with Audio Highlight

    private var substitutionView: some View {
        let words = verse.words?.filter { $0.isWord } ?? []
        return WrappingHStack(alignment: .leading, spacing: 4) {
            ForEach(words) { word in
                let isHighlighted = currentWordIndex != nil && word.position == currentWordIndex
                let display = vocabularyStore.displayMode(for: word)

                SubstitutionWordView(
                    word: word,
                    display: display,
                    isHighlighted: isHighlighted,
                    verseKey: verse.verseKey
                )
            }
        }
        .lineSpacing(8)
    }
}
