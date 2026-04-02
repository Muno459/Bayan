import AVFoundation
import SwiftUI

/// A single word in the substitution line. Tapping a substituted word
/// shows a popover with its English meaning, transliteration, and Arabic script.
/// Includes a play button to hear the word pronounced.
struct SubstitutionWordView: View {
    let word: Word
    let display: SubstitutionDisplay
    let isHighlighted: Bool

    @Environment(AudioPlaybackManager.self) private var audioManager
    @State private var showDetail = false
    @State private var isPlayingWord = false

    var body: some View {
        wordContent
            .onTapGesture {
                // Only show detail for non-English words (substituted ones)
                if !isEnglishDisplay {
                    showDetail = true
                }
            }
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                wordDetailPopover
                    .presentationCompactAdaptation(.popover)
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
                        RoundedRectangle(cornerRadius: 6)
                            .fill(BayanColors.primary.opacity(0.1))
                    }
                }

        case .transliteration(let text):
            Text(text)
                .font(.system(size: isHighlighted ? 19 : 17, weight: .semibold, design: .serif))
                .foregroundStyle(isHighlighted ? .white : BayanColors.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, isHighlighted ? 3 : 1)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHighlighted ? BayanColors.primary : BayanColors.primary.opacity(0.08))
                )

        case .transitioning(let transliteration, let english):
            VStack(spacing: 0) {
                Text(transliteration)
                    .font(.system(size: isHighlighted ? 18 : 16, weight: .medium, design: .serif))
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

    // MARK: - Detail Popover

    private var wordDetailPopover: some View {
        VStack(spacing: 14) {
            // Arabic script large + play button
            HStack(spacing: 12) {
                Spacer()

                Text(word.textUthmani ?? "")
                    .font(.system(size: 34, design: .serif))
                    .foregroundStyle(BayanColors.textPrimary)

                // Play pronunciation
                Button {
                    Task { await playWordAudio() }
                } label: {
                    Image(systemName: isPlayingWord ? "speaker.wave.2.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(BayanColors.primary)
                        .symbolEffect(.pulse, isActive: isPlayingWord)
                }

                Spacer()
            }

            Divider()

            // Transliteration
            HStack {
                Text("Sounds like")
                    .font(.system(size: 12))
                    .foregroundStyle(BayanColors.textSecondary)
                Spacer()
                Text(word.transliteration?.text ?? "—")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(BayanColors.primary)
            }

            // English meaning
            HStack {
                Text("Meaning")
                    .font(.system(size: 12))
                    .foregroundStyle(BayanColors.textSecondary)
                Spacer()
                Text(word.translation?.text ?? "—")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(BayanColors.textPrimary)
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    // MARK: - Word Audio

    /// Play just this word by seeking the chapter audio to the word's timestamp.
    /// Uses the AudioPlaybackManager's loaded audio if available,
    /// otherwise uses iOS text-to-speech as fallback.
    private func playWordAudio() async {
        isPlayingWord = true

        // Try using the already-loaded chapter audio with word timing
        if audioManager.playWordClip(wordPosition: word.position) {
            // Word clip will play for its duration, then we reset
            try? await Task.sleep(for: .seconds(1.5))
        } else {
            // Fallback: use AVSpeechSynthesizer for the Arabic text
            let utterance = AVSpeechUtterance(string: word.textUthmani ?? "")
            utterance.voice = AVSpeechSynthesisVoice(language: "ar-SA")
            utterance.rate = 0.4
            let synthesizer = AVSpeechSynthesizer()
            synthesizer.speak(utterance)
            try? await Task.sleep(for: .seconds(2))
        }

        isPlayingWord = false
    }
}
