import SwiftUI

/// A single word in the substitution line. Tapping an Arabic word
/// opens a learning card with meaning, pronunciation drill, and frequency.
struct SubstitutionWordView: View {
    let word: Word
    let display: SubstitutionDisplay
    let isHighlighted: Bool
    let verseKey: String

    @Environment(SettingsManager.self) private var settings
    @Environment(VocabularyStore.self) private var vocabularyStore
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
                    wordPlayer: $wordPlayer,
                    vocabularyStore: vocabularyStore
                )
                .presentationDetents([.fraction(0.4), .medium])
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
            StableHighlight(isHighlighted: isHighlighted) {
                Text(text)
                    .font(.system(size: 20))
                    .foregroundStyle(isHighlighted ? BayanColors.primary : BayanColors.textPrimary)
            } background: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHighlighted ? BayanColors.primary.opacity(0.12) : .clear)
            }

        case .arabic(let text):
            StableHighlight(isHighlighted: isHighlighted) {
                Text(text)
                    .font(.system(size: 26, design: .serif))
                    .foregroundStyle(isHighlighted ? .white : BayanColors.primary)
            } background: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHighlighted ? BayanColors.primary : BayanColors.primary.opacity(0.08))
            }

        case .transitioning(let arabic, let english):
            StableHighlight(isHighlighted: isHighlighted) {
                VStack(spacing: 0) {
                    Text(arabic)
                        .font(.system(size: 24, design: .serif))
                        .foregroundStyle(isHighlighted ? BayanColors.primary : BayanColors.primary.opacity(0.85))
                    Text(english)
                        .font(.system(size: 10))
                        .foregroundStyle(BayanColors.textSecondary.opacity(0.6))
                }
            } background: {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHighlighted ? BayanColors.learning.opacity(0.15) : BayanColors.learning.opacity(0.05))
            }
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
    let vocabularyStore: VocabularyStore

    private var frequency: Int? {
        QuranicWordData.frequency(for: word.textUthmani ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Arabic word + meaning side by side (RTL: Arabic on right)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(word.translation?.text ?? "")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(BayanColors.textSecondary)

                        if let freq = frequency {
                            Text("Appears \(freq)x in the Quran")
                                .font(.system(size: 11))
                                .foregroundStyle(BayanColors.primary.opacity(0.7))
                        }
                    }

                    Spacer()

                    Text(word.textUthmani ?? "")
                        .font(.system(size: 38, design: .serif))
                        .foregroundStyle(BayanColors.textPrimary)
                }
                .padding(.top, 16)

                // Audio controls — compact row
                HStack(spacing: 24) {
                    Button {
                        wordPlayer.play(verseKey: verseKey, wordPosition: word.position)
                    } label: {
                        Label(
                            wordPlayer.isPlaying && !wordPlayer.isDrilling ? "Playing" : "Listen",
                            systemImage: wordPlayer.isPlaying && !wordPlayer.isDrilling ? "speaker.wave.2.fill" : "play.circle.fill"
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(BayanColors.primary)
                        .symbolEffect(.variableColor.iterative, isActive: wordPlayer.isPlaying && !wordPlayer.isDrilling)
                    }

                    Button {
                        wordPlayer.drill(verseKey: verseKey, wordPosition: word.position)
                    } label: {
                        Label(
                            wordPlayer.isDrilling ? drillStepLabel : "Practice 3x",
                            systemImage: wordPlayer.isDrilling ? "waveform" : "repeat"
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(wordPlayer.isDrilling ? BayanColors.gold : BayanColors.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative.reversing, isActive: wordPlayer.isDrilling)
                    }
                }
                .padding(.vertical, 6)

                // Drill status / error
                if wordPlayer.isDrilling {
                    Text(drillStatusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BayanColors.gold)
                        .transition(.opacity)
                }
                if let error = wordPlayer.error {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.8))
                }

                // Try Pronouncing
                PronunciationButton(expectedArabic: word.textUthmani ?? "")

                Divider()

                // Letter breakdown
                LetterBreakdownView(arabicText: word.textUthmani ?? "")

                // "I Know This" button
                if let state = vocabularyStore.wordStates[word.id], state.masteryLevel < .familiar {
                    Button {
                        Haptics.success()
                        vocabularyStore.promote(wordId: word.id)
                        vocabularyStore.promote(wordId: word.id)
                    } label: {
                        Label("I Know This Word", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(BayanColors.mastered))
                    }
                    .padding(.horizontal, 24)
                } else if vocabularyStore.wordStates[word.id] != nil {
                    Label("You know this word!", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BayanColors.mastered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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
