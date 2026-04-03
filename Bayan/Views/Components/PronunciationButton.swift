import SwiftUI

/// Button that lets users practice pronouncing an Arabic word.
/// Records audio, runs on-device Tarteel Whisper model, shows result.
struct PronunciationButton: View {
    let expectedArabic: String
    @State private var checker = PronunciationChecker()

    var body: some View {
        VStack(spacing: 8) {
            switch checker.state {
            case .idle:
                Button {
                    Haptics.medium()
                    Task {
                        await checker.loadModel()
                        checker.startRecording()
                    }
                } label: {
                    Label("Try Pronouncing", systemImage: "mic.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(BayanColors.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(BayanColors.primary.opacity(0.08))
                        )
                }

            case .recording:
                VStack(spacing: 6) {
                    // Recording indicator
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Listening... say the word")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(BayanColors.textSecondary)
                    }

                    Button {
                        Haptics.light()
                        Task {
                            await checker.stopRecording(expectedArabic: expectedArabic)
                        }
                    } label: {
                        Label("Done", systemImage: "stop.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.red))
                    }
                }

            case .processing:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Checking pronunciation...")
                        .font(.system(size: 13))
                        .foregroundStyle(BayanColors.textSecondary)
                }

            case .result(let correct, let transcription):
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: correct ? "checkmark.circle.fill" : "arrow.counterclockwise.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)

                        Text(correct ? "Great pronunciation!" : "Try again")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                    }

                    if !transcription.isEmpty {
                        Text("Heard: \(transcription)")
                            .font(.system(size: 11))
                            .foregroundStyle(BayanColors.textSecondary)
                    }

                    Button {
                        checker.reset()
                    } label: {
                        Text("Try Again")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(BayanColors.primary)
                    }
                }

            case .error(let message):
                VStack(spacing: 4) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.8))
                    Button {
                        checker.reset()
                    } label: {
                        Text("Try Again")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(BayanColors.primary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
