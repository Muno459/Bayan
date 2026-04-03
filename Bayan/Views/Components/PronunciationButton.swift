import SwiftUI

/// Pronunciation practice with auto-stop, visual feedback, and celebration.
struct PronunciationButton: View {
    let expectedArabic: String
    @Environment(SettingsManager.self) private var settings
    @State private var checker = PronunciationChecker()
    @State private var autoStarted = false
    @State private var recordingPulse = false

    var body: some View {
        VStack(spacing: 8) {
            switch checker.state {
            case .idle, .loading:
                Button {
                    Haptics.medium()
                    startListening()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14))
                        Text(checker.state == .loading ? "Loading..." : "Say This Word")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(BayanColors.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(BayanColors.primary.opacity(0.08)))
                }
                .disabled(checker.state == .loading)
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
                // Pulsing mic with "Listening..."
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(recordingPulse ? 1.3 : 0.8)
                        .animation(.easeInOut(duration: 0.5).repeatForever(), value: recordingPulse)

                    Text("Listening...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red)

                    // Manual stop button
                    Button {
                        Task {
                            await checker.stopRecording(expectedArabic: expectedArabic)
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                }
                .onAppear {
                    recordingPulse = true
                    // Auto-stop after 4 seconds max
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        if case .recording = checker.state {
                            await checker.stopRecording(expectedArabic: expectedArabic)
                        }
                        recordingPulse = false
                    }
                }

            case .processing:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Checking...")
                        .font(.system(size: 13))
                        .foregroundStyle(BayanColors.textSecondary)
                }

            case .result(let correct, let transcription):
                VStack(spacing: 6) {
                    // Success / failure with icon
                    HStack(spacing: 5) {
                        Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                            .symbolEffect(.bounce, value: correct)

                        Text(correct ? "Excellent!" : "Not quite")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                    }

                    // Show what they said if incorrect
                    if !correct && !transcription.isEmpty {
                        HStack(spacing: 4) {
                            Text("Heard:")
                                .font(.system(size: 11))
                                .foregroundStyle(BayanColors.textSecondary)
                            Text(transcription)
                                .font(.system(size: 13))
                                .foregroundStyle(BayanColors.learning)
                        }
                    }

                    // Try again button (on failure) or auto-dismiss (on success)
                    if !correct {
                        Button {
                            checker.reset()
                        } label: {
                            Text("Try Again")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(BayanColors.primary)
                        }
                    }
                }
                .onAppear {
                    if correct {
                        Haptics.success()
                        // Auto-dismiss after 2s on success
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            checker.reset()
                        }
                    } else {
                        Haptics.medium()
                    }
                }

            case .error(let msg):
                VStack(spacing: 4) {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(BayanColors.textSecondary)
                    Button { checker.reset() } label: {
                        Text("Retry")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BayanColors.primary)
                    }
                }
            }
        }
    }

    private func startListening() {
        Task {
            if !checker.isModelLoaded {
                await checker.loadModel()
            }
            guard checker.isModelLoaded else { return }
            checker.startRecording()
        }
    }
}
