import SwiftUI

/// Shows a featured "Word of the Day" card with Arabic script and meaning.
struct DailyWordCard: View {
    @Environment(VocabularyStore.self) private var vocabularyStore

    private var dailyWord: WordLearningState? {
        let allWords = Array(vocabularyStore.wordStates.values)
            .filter { !$0.arabicText.isEmpty }
            .sorted { $0.wordId < $1.wordId }
        guard !allWords.isEmpty else { return nil }
        let dayIndex = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return allWords[dayIndex % allWords.count]
    }

    var body: some View {
        if let word = dailyWord {
            VStack(alignment: .leading, spacing: 12) {
                Label("Word of the Day", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BayanColors.gold)

                HStack(alignment: .center, spacing: 16) {
                    let displayText = vocabularyStore.useTransliteration && !word.transliterationText.isEmpty
                        ? word.transliterationText : word.arabicText
                    Text(displayText)
                        .font(.system(size: vocabularyStore.useTransliteration ? 24 : 32))
                        .foregroundStyle(BayanColors.primary)

                    Spacer()

                    Text(word.translationText)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(BayanColors.textPrimary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(BayanColors.gold.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(BayanColors.gold.opacity(0.15), lineWidth: 1))
            )
        }
    }
}
