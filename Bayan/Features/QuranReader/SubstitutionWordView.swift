import SwiftUI

/// A single word in the substitution line. Tapping an Arabic word
/// opens a learning card with meaning, pronunciation drill, and frequency.
struct SubstitutionWordView: View {
    let word: Word
    let display: SubstitutionDisplay
    let isHighlighted: Bool
    let verseKey: String

    @Environment(SettingsManager.self) private var settings
    @State private var showDetail = false
    @State private var wordPlayer = WordAudioPlayer()

    var body: some View {
        wordContent
            .onTapGesture {
                if !isEnglishDisplay {
                    Haptics.light()
                    showDetail = true
                }
            }
            .sheet(isPresented: $showDetail) {
                wordPlayer.stop()
            } content: {
                WordLearningCard(
                    word: word,
                    verseKey: verseKey,
                    wordPlayer: $wordPlayer
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: showDetail) { _, isShowing in
                if isShowing && settings.autoPlayWordPronunciation {
                    wordPlayer.play(verseKey: verseKey, wordPosition: word.position)
                }
            }
    }

    private var isEnglishDisplay: Bool {
        if case .english = display { return true }
        return false
    }

    // MARK: - Word Display

    @ViewBuilder
    private var wordContent: some View {
        switch display {
        case .english(let text):
            Text(text)
                .font(.system(size: isHighlighted ? 19 : 17))
                .fontWeight(isHighlighted ? .bold : .regular)
                .foregroundStyle(isHighlighted ? BayanColors.primary : BayanColors.textPrimary)
                .padding(.horizontal, isHighlighted ? 4 : 0)
                .padding(.vertical, isHighlighted ? 2 : 0)
                .background {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 6).fill(BayanColors.primary.opacity(0.1))
                    }
                }

        case .arabic(let text):
            Text(text)
                .font(.system(size: isHighlighted ? 24 : 22, design: .serif))
                .foregroundStyle(isHighlighted ? .white : BayanColors.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, isHighlighted ? 3 : 1)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHighlighted ? BayanColors.primary : BayanColors.primary.opacity(0.08))
                )

        case .transitioning(let arabic, let english):
            VStack(spacing: 0) {
                Text(arabic)
                    .font(.system(size: isHighlighted ? 22 : 20, design: .serif))
                    .foregroundStyle(isHighlighted ? BayanColors.primary : BayanColors.primary.opacity(0.85))
                Text(english)
                    .font(.system(size: 9))
                    .foregroundStyle(BayanColors.textSecondary.opacity(0.6))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, isHighlighted ? 2 : 0)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHighlighted ? BayanColors.learning.opacity(0.12) : BayanColors.learning.opacity(0.05))
            )
        }
    }
}

// MARK: - Word Learning Card (Sheet)

/// Full learning card shown as a sheet when tapping an Arabic word.
/// Shows: Arabic large, meaning, play button, drill button, frequency.
struct WordLearningCard: View {
    let word: Word
    let verseKey: String
    @Binding var wordPlayer: WordAudioPlayer
    @Environment(VocabularyStore.self) private var vocabularyStore

    private var frequency: Int? {
        QuranicWordData.frequency(for: word.textUthmani ?? "")
    }

    var body: some View {
        VStack(spacing: 24) {
            // Arabic word — large, centered
            Text(word.textUthmani ?? "")
                .font(.system(size: 56, design: .serif))
                .foregroundStyle(BayanColors.textPrimary)
                .padding(.top, 20)

            // English meaning
            Text(word.translation?.text ?? "")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BayanColors.textSecondary)

            Divider().padding(.horizontal, 32)

            // Audio controls
            HStack(spacing: 20) {
                // Single play
                Button {
                    wordPlayer.play(verseKey: verseKey, wordPosition: word.position)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: wordPlayer.isPlaying && !wordPlayer.isDrilling
                              ? "speaker.wave.2.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(BayanColors.primary)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.variableColor.iterative, isActive: wordPlayer.isPlaying && !wordPlayer.isDrilling)
                        Text("Listen")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BayanColors.textSecondary)
                    }
                }

                // Drill (3x: normal → slow → normal)
                Button {
                    wordPlayer.drill(verseKey: verseKey, wordPosition: word.position)
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Image(systemName: wordPlayer.isDrilling ? "waveform" : "repeat")
                                .font(.system(size: 28))
                                .foregroundStyle(wordPlayer.isDrilling ? BayanColors.gold : BayanColors.primary)
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.variableColor.iterative.reversing, isActive: wordPlayer.isDrilling)

                            if wordPlayer.isDrilling {
                                Text(drillStepLabel)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(BayanColors.gold)
                                    .offset(y: 18)
                            }
                        }
                        .frame(height: 32)

                        Text(wordPlayer.isDrilling ? "Practicing..." : "Practice")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(wordPlayer.isDrilling ? BayanColors.gold : BayanColors.textSecondary)
                    }
                }
            }
            .padding(.vertical, 8)

            // Drill explanation
            if wordPlayer.isDrilling {
                Text(drillStatusText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BayanColors.gold)
                    .transition(.opacity)
            }

            // Word frequency
            if let freq = frequency {
                HStack(spacing: 6) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 14))
                        .foregroundStyle(BayanColors.primary)
                    Text("Appears \(freq) time\(freq == 1 ? "" : "s") in the Quran")
                        .font(.system(size: 14))
                        .foregroundStyle(BayanColors.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(BayanColors.primary.opacity(0.05))
                )
            }

            // Letter breakdown — teach Arabic reading
            LetterBreakdownView(arabicText: word.textUthmani ?? "")

            // "I Know This" button
            if let state = vocabularyStore.wordStates[word.id], state.masteryLevel < .familiar {
                Button {
                    Haptics.success()
                    vocabularyStore.promote(wordId: word.id)
                    vocabularyStore.promote(wordId: word.id) // double promote to familiar
                } label: {
                    Label("I Know This Word", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(BayanColors.mastered))
                }
                .padding(.horizontal, 32)
            } else if vocabularyStore.wordStates[word.id] != nil {
                Label("You know this word!", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BayanColors.mastered)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(BayanColors.background)
        .animation(.easeInOut(duration: 0.2), value: wordPlayer.isDrilling)
        .animation(.easeInOut(duration: 0.2), value: wordPlayer.drillStep)
    }

    private var drillStepLabel: String {
        switch wordPlayer.drillStep {
        case 0: "1x"
        case 1: "slow"
        case 2: "1x"
        default: ""
        }
    }

    private var drillStatusText: String {
        switch wordPlayer.drillStep {
        case 0: "Listening at normal speed..."
        case 1: "Now slower... listen carefully"
        case 2: "One more time, normal speed"
        default: ""
        }
    }
}
