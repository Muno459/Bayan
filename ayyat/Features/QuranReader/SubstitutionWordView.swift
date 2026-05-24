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
    @Environment(AudioPlaybackManager.self) private var audioManager
    @State private var showDetail = false
    @State private var wordPlayer = WordAudioPlayer()
    @State private var autoPlayTask: Task<Void, Never>?

    var body: some View {
        wordContent
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.32), value: displayKey)
            .onTapGesture {
                if !isEnglishDisplay {
                    Haptics.light()
                    vocabularyStore.recordTap(for: word)
                    // If this word's lemma had graduated to bare Arabic
                    // and the user needed to tap for help, that's an
                    // honest "I forgot" signal — demote to training wheels
                    // (Arabic + faded transliteration) for the next few
                    // reads. Tapping a still-training-wheels word does
                    // NOT demote; users are allowed to consult during the
                    // graduation window.
                    if case .learned = display {
                        vocabularyStore.recordDemotionTap(lemmaText: word.lemmaText)
                    }
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
                // Default to .medium so the letter breakdown + "I Know This"
                // button are visible without scrolling, and the sheet has
                // room to grow when a pronunciation result appears below
                // the mic. Still expandable to .large for long words.
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: showDetail) { _, isShowing in
                autoPlayTask?.cancel()
                guard isShowing, settings.autoPlayWordPronunciation else { return }
                // Suppress auto-play when the full surah recitation is
                // already playing — otherwise the per-word audio talks
                // over the reciter mid-ayah. The user can still tap
                // "Listen" on the card itself.
                guard !audioManager.isPlaying else { return }
                // Tiny delay so the sheet finishes presenting before audio
                // starts. Stored so we cancel if the user dismisses the
                // sheet within that 150 ms, otherwise the player would
                // start playing into the void.
                autoPlayTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, showDetail else { return }
                    wordPlayer.play(verseKey: verseKey, wordPosition: word.position)
                }
            }
    }

    private var isEnglishDisplay: Bool {
        if case .english = display { return true }
        return false
    }

    /// Stable comparison key for the substitution display state. Drives the
    /// fade/scale animation when a word swaps from English to Arabic (or vice
    /// versa) as the user moves the substitution slider.
    private var displayKey: String {
        switch display {
        case .english(let s):       "en:\(s)"
        case .learned(let s):       "ar:\(s)"
        case .transitioning(let a, let b): "tr:\(a):\(b)"
        }
    }

    private func isArabicText(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x0600 && $0.value <= 0x06FF }
    }

    // MARK: - Word Display

    /// Base size for English glyphs; Arabic is a touch larger for readability.
    private var englishSize: CGFloat { settings.arabicFontSize - 6 }
    private var arabicSize: CGFloat  { settings.arabicFontSize }

    @ViewBuilder
    private var wordContent: some View {
        switch display {
        case .english(let text):
            Text(text)
                .font(.system(size: englishSize))
                .foregroundStyle(isHighlighted ? AyyatColors.primary : AyyatColors.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHighlighted ? AyyatColors.primary.opacity(0.1) : .clear)
                )

        case .learned(let text):
            Text(text)
                .font(isArabicText(text)
                      ? .system(size: arabicSize)
                      : .system(size: englishSize, weight: .semibold))
                .environment(\.locale, isArabicText(text) ? Locale(identifier: "ar") : .current)
                .foregroundStyle(isHighlighted ? .white : AyyatColors.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHighlighted ? AyyatColors.primary : AyyatColors.primary.opacity(0.08))
                )

        case .transitioning(let target, let english):
            VStack(spacing: 0) {
                Text(target)
                    .font(isArabicText(target)
                          ? .system(size: arabicSize - 2)
                          : .system(size: englishSize - 2, weight: .medium))
                    .environment(\.locale, isArabicText(target) ? Locale(identifier: "ar") : .current)
                    .foregroundStyle(isHighlighted ? AyyatColors.primary : AyyatColors.primary.opacity(0.85))
                Text(english)
                    .font(.system(size: max(9, englishSize - 12)))
                    .foregroundStyle(AyyatColors.textSecondary.opacity(0.6))
            }
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHighlighted ? AyyatColors.learning.opacity(0.15) : AyyatColors.learning.opacity(0.05))
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
    let vocabularyStore: VocabularyStore
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private var frequency: Int? {
        QuranicWordData.frequency(for: word.textUthmani ?? "")
    }

    private var pronunciationState: PronunciationChecker.State {
        SharedPronunciationChecker.checker.state
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Arabic word + meaning side by side (RTL: Arabic on right)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(word.translation?.text ?? "")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AyyatColors.textSecondary)

                        if let freq = frequency {
                            Text("Appears \(freq)x in the Quran")
                                .font(.system(size: 11))
                                .foregroundStyle(AyyatColors.primary.opacity(0.7))
                        }
                    }

                    Spacer()

                    Text(word.textUthmani ?? "")
                        .font(.system(size: 38))
                        .foregroundStyle(AyyatColors.textPrimary)
                }
                .padding(.top, 16)

                // Transliteration guide (optional)
                if settings.showTransliteration, let translit = word.transliteration?.text, !translit.isEmpty {
                    Text(translit)
                        .font(.system(size: 15))
                        .italic()
                        .foregroundStyle(AyyatColors.textSecondary.opacity(0.7))
                }

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
                        .foregroundStyle(AyyatColors.primary)
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
                        .foregroundStyle(wordPlayer.isDrilling ? AyyatColors.gold : AyyatColors.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative.reversing, isActive: wordPlayer.isDrilling)
                    }
                }
                .padding(.vertical, 6)

                // Drill status / error
                if wordPlayer.isDrilling {
                    Text(drillStatusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AyyatColors.gold)
                        .transition(.opacity)
                }
                if let error = wordPlayer.error {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.8))
                }

                // Try Pronouncing - reset state when card appears
                // Use word.id as identity so SwiftUI creates fresh view for each word
                PronunciationButton(expectedArabic: word.textUthmani ?? "")
                    .id(word.id)
                    .onAppear {
                        SharedPronunciationChecker.checker.reset()
                    }
                    .onChange(of: pronunciationState) { _, newState in
                        if case .result(let correct, _) = newState, correct {
                            vocabularyStore.recordSuccess(for: word.id)
                        }
                    }

                Divider()

                // Letter breakdown
                LetterBreakdownView(arabicText: word.textUthmani ?? "")

                // "I Know This" button. Tapping it promotes the word and
                // dismisses the sheet immediately — the verse cell behind
                // re-renders with the word now substituted in Arabic. No
                // need to keep the explainer card around once the user has
                // already self-declared mastery.
                if let state = vocabularyStore.wordStates[word.id], state.masteryLevel < .familiar {
                    Button {
                        Haptics.success()
                        vocabularyStore.markAsFamiliar(wordId: word.id)
                        // Same tap also marks the LEMMA learned, which silently
                        // unlocks every inflection of this word across the
                        // Quran for substitution. The user never sees the word
                        // "lemma" — they just notice, on next read, that other
                        // verses now show this word in Arabic instead of
                        // English. The dignity of compound discovery, not the
                        // dopamine of an announcement.
                        vocabularyStore.markLemmaLearned(word.lemmaText)
                        // Stop any in-flight drill audio, then close the
                        // sheet on the next runloop tick to let the haptic
                        // and animation start before the view tears down.
                        wordPlayer.stop()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            dismiss()
                        }
                    } label: {
                        Label("I Know This Word", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(AyyatColors.mastered))
                    }
                    .padding(.horizontal, 24)
                } else if vocabularyStore.wordStates[word.id] != nil {
                    Label("You know this word!", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AyyatColors.mastered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(AyyatColors.background)
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
