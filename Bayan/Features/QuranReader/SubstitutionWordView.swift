import SwiftUI

/// A single word in the substitution line. Tapping a substituted (Arabic) word
/// shows a popover with its English meaning and play button.
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
            .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                wordDetailPopover
                    .presentationCompactAdaptation(.popover)
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
                        RoundedRectangle(cornerRadius: 6)
                            .fill(BayanColors.primary.opacity(0.1))
                    }
                }

        case .arabic(let text):
            // Learned word — Arabic script in accent color
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
            // Learning — Arabic script with small English hint below
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

    // MARK: - Detail Popover

    private var wordDetailPopover: some View {
        VStack(spacing: 14) {
            // Arabic script large + play
            HStack(spacing: 12) {
                Spacer()

                Text(word.textUthmani ?? "")
                    .font(.system(size: 36, design: .serif))
                    .foregroundStyle(BayanColors.textPrimary)

                Button {
                    wordPlayer.play(verseKey: verseKey, wordPosition: word.position)
                } label: {
                    Image(systemName: wordPlayer.isPlaying ? "speaker.wave.2.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(BayanColors.primary)
                        .symbolEffect(.pulse, isActive: wordPlayer.isPlaying)
                }

                Spacer()
            }

            Divider()

            // English meaning
            HStack {
                Text("Meaning")
                    .font(.system(size: 12))
                    .foregroundStyle(BayanColors.textSecondary)
                Spacer()
                Text(word.translation?.text ?? "")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(BayanColors.textPrimary)
            }
        }
        .padding(16)
        .frame(width: 240)
    }
}
