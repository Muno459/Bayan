import SwiftUI

/// Auto-mic pronunciation checker. Opens mic automatically when the word
/// learning card appears, shows a visual waveform animation, then gives
/// feedback. Only triggers on faithful attempts (similarity > 0.3).
struct PronunciationButton: View {
    let expectedArabic: String
    @Environment(SettingsManager.self) private var settings
    @State private var checker = PronunciationChecker()
    @State private var pulseScale: CGFloat = 1.0
    @State private var autoStarted = false

    var body: some View {
        VStack(spacing: 6) {
            switch checker.state {
            case .idle, .loading:
                Button {
                    Haptics.medium()
                    startListening()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16))
                        Text("Say This Word")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(BayanColors.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(BayanColors.primary.opacity(0.08)))
                }
                .onAppear {
                    if settings.autoPronunciationCheck && !autoStarted {
                        autoStarted = true
                        Task {
                            try? await Task.sleep(for: .milliseconds(800))
                            startListening()
                        }
                    }
                }

            case .recording:
                VStack(spacing: 4) {
                    // Pulsing mic animation
                    ZStack {
                        Circle()
                            .fill(BayanColors.primary.opacity(0.08))
                            .frame(width: 56, height: 56)
                            .scaleEffect(pulseScale)

                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(BayanColors.primary)
                    }
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            pulseScale = 1.3
                        }
                    }

                    Text("Listening...")
                        .font(.system(size: 12))
                        .foregroundStyle(BayanColors.textSecondary)
                }
                .onAppear {
                    // Auto-stop after 3 seconds
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        if case .recording = checker.state {
                            await checker.stopRecording(expectedArabic: expectedArabic)
                            pulseScale = 1.0
                        }
                    }
                }

            case .processing:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Checking...")
                        .font(.system(size: 12))
                        .foregroundStyle(BayanColors.textSecondary)
                }

            case .result(let correct, _):
                HStack(spacing: 6) {
                    Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                        .symbolEffect(.bounce, value: correct)

                    Text(correct ? "Well done!" : "Try again")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                }
                .onAppear {
                    Haptics.success()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        checker.reset()
                    }
                }

            case .error:
                Button {
                    checker.reset()
                } label: {
                    Label("Tap to retry", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(BayanColors.textSecondary)
                }
            }
        }
    }

    private func startListening() {
        Task {
            if case .idle = checker.state {
                await checker.loadModel()
            }
            checker.startRecording()
        }
    }
}
