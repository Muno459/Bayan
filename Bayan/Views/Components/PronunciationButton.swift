import SwiftUI

/// Compact pronunciation practice button.
/// Tap mic to record, auto-stops after 3s, shows result inline.
struct PronunciationButton: View {
    let expectedArabic: String
    @Environment(SettingsManager.self) private var settings
    @State private var checker = PronunciationChecker()
    @State private var autoStarted = false

    var body: some View {
        Group {
            switch checker.state {
            case .idle, .loading:
                Button {
                    Haptics.medium()
                    startListening()
                } label: {
                    Label("Say This Word", systemImage: "mic.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BayanColors.primary)
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
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("Listening...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                }
                .onAppear {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        if case .recording = checker.state {
                            await checker.stopRecording(expectedArabic: expectedArabic)
                        }
                    }
                }

            case .processing:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Checking...")
                        .font(.system(size: 13))
                        .foregroundStyle(BayanColors.textSecondary)
                }

            case .result(let correct, _):
                HStack(spacing: 4) {
                    Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                    Text(correct ? "Well done!" : "Try again")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                }
                .onAppear {
                    correct ? Haptics.success() : Haptics.medium()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        checker.reset()
                    }
                }

            case .error:
                Button { checker.reset() } label: {
                    Label("Retry", systemImage: "arrow.counterclockwise")
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
