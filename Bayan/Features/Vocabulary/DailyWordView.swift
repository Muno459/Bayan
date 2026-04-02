import SwiftUI

/// Shows a featured "Word of the Day" card.
struct DailyWordCard: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @State private var wordPlayer = WordAudioPlayer()

    private var dailyWord: WordLearningState? {
        // Pick a word based on the day — deterministic so it's the same all day
        let allWords = Array(vocabularyStore.wordStates.values)
            .filter { !$0.transliterationText.isEmpty }
            .sorted { $0.wordId < $1.wordId }

        guard !allWords.isEmpty else { return nil }

        let dayIndex = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return allWords[dayIndex % allWords.count]
    }

    var body: some View {
        if let word = dailyWord {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Word of the Day", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BayanColors.gold)
                    Spacer()

                    Button {
                        // Can't derive verse key here easily, so skip CDN audio
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 14))
                            .foregroundStyle(BayanColors.primary)
                    }
                }

                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(word.transliterationText)
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(BayanColors.primary)

                        Text(word.translationText)
                            .font(.system(size: 15))
                            .foregroundStyle(BayanColors.textPrimary)
                    }

                    Spacer()

                    Text(word.arabicText)
                        .font(.system(size: 28, design: .serif))
                        .foregroundStyle(BayanColors.textSecondary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(BayanColors.gold.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(BayanColors.gold.opacity(0.15), lineWidth: 1)
                    )
            )
        }
    }
}
