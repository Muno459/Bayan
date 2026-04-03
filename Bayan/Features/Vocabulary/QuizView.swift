import SwiftUI

/// Flashcard quiz: Arabic script on front, meaning on back.
/// Swipe right = Got It, swipe left = Still Learning.
/// Tap to flip the card.
struct QuizView: View {
    @Environment(VocabularyStore.self) private var vocabularyStore
    @State private var quizWords: [WordLearningState] = []
    @State private var currentIndex = 0
    @State private var isFlipped = false
    @State private var score = 0
    @State private var totalAnswered = 0
    @State private var sessionComplete = false
    @State private var dragOffset: CGSize = .zero
    @State private var cardRotation: Double = 0

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
                quizContent(word: word)
            }
        }
        .navigationTitle("Vocabulary Quiz")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadQuizWords() }
    }

    // MARK: - Quiz Content

    private func quizContent(word: WordLearningState) -> some View {
        VStack(spacing: 0) {
            // Progress
            HStack {
                Text("\(currentIndex + 1) of \(quizWords.count)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BayanColors.textSecondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BayanColors.mastered)
                    Text("\(score)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(BayanColors.mastered)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            // Progress dots
            HStack(spacing: 4) {
                ForEach(0..<quizWords.count, id: \.self) { i in
                    Circle()
                        .fill(i < currentIndex ? BayanColors.primary : (i == currentIndex ? BayanColors.gold : BayanColors.unseen.opacity(0.3)))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 8)

            Spacer()

            // Card with drag gesture
            ZStack {
                // Swipe hint indicators
                if dragOffset.width > 30 {
                    Label("Got It", systemImage: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(BayanColors.mastered)
                        .transition(.opacity)
                }
                if dragOffset.width < -30 {
                    Label("Learning", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(BayanColors.learning)
                        .transition(.opacity)
                }

                // The card
                cardView(word: word)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(dragOffset.width / 20))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                if value.translation.width > 100 {
                                    // Swiped right = Got It
                                    swipeAway(correct: true, word: word)
                                } else if value.translation.width < -100 {
                                    // Swiped left = Still Learning
                                    swipeAway(correct: false, word: word)
                                } else {
                                    // Snap back
                                    withAnimation(.spring(response: 0.3)) {
                                        dragOffset = .zero
                                    }
                                }
                            }
                    )
            }

            Spacer()

            // Bottom hint
            if !isFlipped {
                Text("Tap card to reveal meaning")
                    .font(.system(size: 13))
                    .foregroundStyle(BayanColors.textSecondary)
                    .padding(.bottom, 8)
            } else {
                Text("Swipe right if you know it, left if not")
                    .font(.system(size: 13))
                    .foregroundStyle(BayanColors.textSecondary)
                    .padding(.bottom, 8)
            }

            // Button fallback (for accessibility)
            if isFlipped {
                HStack(spacing: 16) {
                    Button { swipeAway(correct: false, word: word) } label: {
                        Label("Still Learning", systemImage: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 12).fill(BayanColors.learning))
                    }
                    Button { swipeAway(correct: true, word: word) } label: {
                        Label("Got It", systemImage: "checkmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 12).fill(BayanColors.mastered))
                    }
                }
                .padding(.horizontal, 24)
                .transition(.opacity)
            }

            Spacer().frame(height: 24)
        }
        .background(BayanColors.background)
    }

    // MARK: - Card View (front/back flip)

    private func cardView(word: WordLearningState) -> some View {
        ZStack {
            // Front: Arabic
            VStack(spacing: 16) {
                Text(word.masteryLevel.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(masteryColor(word.masteryLevel))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(masteryColor(word.masteryLevel).opacity(0.1)))

                Spacer()

                Text(displayText(for: word))
                    .font(.system(size: vocabularyStore.useTransliteration ? 36 : 48))
                    .foregroundStyle(BayanColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("?")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(BayanColors.textSecondary.opacity(0.3))

                Spacer()
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: 340)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
            )
            .opacity(isFlipped ? 0 : 1)
            .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))

            // Back: Meaning
            VStack(spacing: 16) {
                Text(displayText(for: word))
                    .font(.system(size: vocabularyStore.useTransliteration ? 22 : 28))
                    .foregroundStyle(BayanColors.primary)

                Spacer()

                Text(word.translationText)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(BayanColors.textPrimary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: 340)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(.systemBackground))
                    .shadow(color: BayanColors.primary.opacity(0.12), radius: 16, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(BayanColors.primary.opacity(0.15), lineWidth: 1)
                    )
            )
            .opacity(isFlipped ? 1 : 0)
            .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
        }
        .padding(.horizontal, 24)
        .onTapGesture {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.4)) {
                isFlipped.toggle()
            }
        }
    }

    // MARK: - Swipe Away

    private func swipeAway(correct: Bool, word: WordLearningState) {
        Haptics.medium()
        totalAnswered += 1
        if correct {
            score += 1
            vocabularyStore.promote(wordId: word.wordId)
        } else {
            vocabularyStore.demote(wordId: word.wordId)
        }

        // Animate card off screen
        withAnimation(.easeIn(duration: 0.25)) {
            dragOffset = CGSize(width: correct ? 400 : -400, height: 0)
        }

        // Next card after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dragOffset = .zero
            isFlipped = false
            if currentIndex + 1 < quizWords.count {
                currentIndex += 1
            } else {
                sessionComplete = true
            }
        }
    }

    // MARK: - Empty / Completion

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 56))
                .foregroundStyle(BayanColors.primary.opacity(0.3))
            Text("No words to review yet")
                .font(.system(size: 18, weight: .medium))
            Text("Start reading the Quran to build your vocabulary.")
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
            Image(systemName: score == totalAnswered ? "star.fill" : "star.leadinghalf.filled")
                .font(.system(size: 56))
                .foregroundStyle(BayanColors.gold)

            Text("Session Complete")
                .font(.system(size: 24, weight: .bold))

            Text("\(score)/\(totalAnswered)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(BayanColors.primary)

            let pct = totalAnswered > 0 ? Int(Double(score) / Double(totalAnswered) * 100) : 0
            Text("\(pct)% accuracy")
                .font(.system(size: 16))
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
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BayanColors.background)
    }

    // MARK: - Logic

    private func displayText(for word: WordLearningState) -> String {
        if vocabularyStore.useTransliteration {
            return word.transliterationText.isEmpty ? word.arabicText : word.transliterationText
        }
        return word.arabicText
    }

    private func loadQuizWords() {
        quizWords = Array(
            vocabularyStore.wordStates.values
                .filter { $0.masteryLevel >= .introduced && !$0.arabicText.isEmpty }
                .sorted { a, b in
                    if a.masteryLevel != b.masteryLevel { return a.masteryLevel < b.masteryLevel }
                    return (a.lastSeenDate ?? .distantPast) < (b.lastSeenDate ?? .distantPast)
                }
                .prefix(10)
        )
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
