import SwiftUI

/// Flashcard quiz for vocabulary review with spaced repetition.
/// Shows transliteration → user guesses English meaning → reveal + audio.
struct QuizView: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @State private var quizWords: [WordLearningState] = []
    @State private var currentIndex = 0
    @State private var isRevealed = false
    @State private var score = 0
    @State private var totalAnswered = 0
    @State private var wordPlayer = WordAudioPlayer()
    @State private var sessionComplete = false

    private var currentWord: WordLearningState? {
        guard currentIndex < quizWords.count else { return nil }
        return quizWords[currentIndex]
    }

    var body: some View {
        Group {
            if quizWords.isEmpty {
                emptyState
            } else if sessionComplete {
                completionView
            } else if let word = currentWord {
                quizCard(word: word)
            }
        }
        .navigationTitle("Vocabulary Quiz")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadQuizWords() }
    }

    // MARK: - Quiz Card

    private func quizCard(word: WordLearningState) -> some View {
        VStack(spacing: 0) {
            // Progress bar
            ProgressView(value: Double(currentIndex), total: Double(quizWords.count))
                .tint(BayanColors.primary)
                .padding(.horizontal)

            HStack {
                Text("\(currentIndex + 1)/\(quizWords.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BayanColors.textSecondary)
                Spacer()
                Text("Score: \(score)/\(totalAnswered)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BayanColors.primary)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            // Card
            VStack(spacing: 24) {
                // Mastery badge
                Text(word.masteryLevel.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(masteryColor(word.masteryLevel))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(masteryColor(word.masteryLevel).opacity(0.1)))

                // Transliteration — the question
                Text(word.transliterationText)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(BayanColors.primary)
                    .multilineTextAlignment(.center)

                // Play pronunciation
                Button {
                    playWord(word)
                } label: {
                    Label(
                        wordPlayer.isPlaying ? "Playing..." : "Listen",
                        systemImage: wordPlayer.isPlaying ? "speaker.wave.2.fill" : "speaker.wave.2"
                    )
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BayanColors.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(BayanColors.primary.opacity(0.08))
                    )
                }

                if isRevealed {
                    // Revealed: show Arabic + meaning
                    VStack(spacing: 12) {
                        Text(word.arabicText)
                            .font(.system(size: 28, design: .serif))
                            .foregroundStyle(BayanColors.textPrimary)

                        Text(word.translationText)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(BayanColors.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("Did you know it?")
                            .font(.system(size: 14))
                            .foregroundStyle(BayanColors.textSecondary)
                            .padding(.top, 8)

                        // Correct / Wrong buttons
                        HStack(spacing: 16) {
                            Button {
                                answer(correct: false, word: word)
                            } label: {
                                Label("Still Learning", systemImage: "xmark")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(BayanColors.learning)
                                    )
                            }

                            Button {
                                answer(correct: true, word: word)
                            } label: {
                                Label("Got It", systemImage: "checkmark")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(BayanColors.mastered)
                                    )
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    // Tap to reveal
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isRevealed = true
                        }
                    } label: {
                        Text("Tap to Reveal Meaning")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(BayanColors.primary)
                            )
                    }
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
            )
            .padding(.horizontal, 20)

            Spacer()
        }
        .background(BayanColors.background)
    }

    // MARK: - Empty / Completion

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 56))
                .foregroundStyle(BayanColors.primary.opacity(0.3))
            Text("No words to review yet")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(BayanColors.textPrimary)
            Text("Start reading the Quran to build your vocabulary. Words you encounter will appear here for review.")
                .font(.system(size: 14))
                .foregroundStyle(BayanColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BayanColors.background)
    }

    private var completionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "star.fill")
                .font(.system(size: 56))
                .foregroundStyle(BayanColors.gold)

            Text("Session Complete!")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(BayanColors.textPrimary)

            Text("\(score)/\(totalAnswered) correct")
                .font(.system(size: 18))
                .foregroundStyle(BayanColors.primary)

            let pct = totalAnswered > 0 ? Int(Double(score) / Double(totalAnswered) * 100) : 0
            Text("\(pct)% accuracy")
                .font(.system(size: 15))
                .foregroundStyle(BayanColors.textSecondary)

            Button {
                loadQuizWords()
                sessionComplete = false
                currentIndex = 0
                score = 0
                totalAnswered = 0
            } label: {
                Text("Practice Again")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(BayanColors.primary))
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BayanColors.background)
    }

    // MARK: - Logic

    private func loadQuizWords() {
        // Pick words that need review: introduced and learning first, then familiar
        var reviewWords = vocabularyStore.wordStates.values
            .filter { $0.masteryLevel >= .introduced && !$0.transliterationText.isEmpty }
            .sorted { a, b in
                // Prioritize: learning > introduced > familiar > mastered
                if a.masteryLevel != b.masteryLevel {
                    return a.masteryLevel < b.masteryLevel
                }
                // Then by least recently seen
                return (a.lastSeenDate ?? .distantPast) < (b.lastSeenDate ?? .distantPast)
            }

        // Cap at 10 words per session
        quizWords = Array(reviewWords.prefix(10))
    }

    private func answer(correct: Bool, word: WordLearningState) {
        totalAnswered += 1
        if correct {
            score += 1
            vocabularyStore.promote(wordId: word.wordId)
        } else {
            vocabularyStore.demote(wordId: word.wordId)
        }

        // Next card
        withAnimation(.easeInOut(duration: 0.3)) {
            isRevealed = false
            if currentIndex + 1 < quizWords.count {
                currentIndex += 1
            } else {
                sessionComplete = true
            }
        }
    }

    private func playWord(_ word: WordLearningState) {
        // Derive verse key from word — we stored it during exposure
        // For now use a simplified approach: play the Arabic via the CDN
        // This requires knowing the verse key which we'll add to WordLearningState later
        // Fallback: just play the arabic text via word position 1
        // TODO: Store verseKey in WordLearningState for accurate playback
    }

    private func masteryColor(_ level: MasteryLevel) -> Color {
        switch level {
        case .unseen: BayanColors.unseen
        case .introduced: BayanColors.introduced
        case .learning: BayanColors.learning
        case .familiar: BayanColors.introduced
        case .mastered: BayanColors.mastered
        }
    }
}
