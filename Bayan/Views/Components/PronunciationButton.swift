import AVFoundation
import SwiftUI

/// Pronunciation practice with preloaded model, live waveform, and VAD.
/// Model is preloaded at app launch — recording starts instantly.
struct PronunciationButton: View {
    let expectedArabic: String
    @Environment(SettingsManager.self) private var settings
    @State private var audioLevels: [CGFloat] = Array(repeating: 0.03, count: 20)
    @State private var meterTimer: Timer?
    @State private var silenceFrames = 0
    @State private var hasDetectedSpeech = false
    @State private var autoStarted = false

    private var checker: PronunciationChecker {
        SharedPronunciationChecker.shared.checker
    }

    private let silenceFramesNeeded = 20 // ~0.8s of silence after speech
    private let barCount = 20

    var body: some View {
        Group {
            switch checker.state {
            case .idle, .loading:
                Button {
                    Haptics.medium()
                    startRecordingImmediately()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13))
                        Text("Say This Word")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(BayanColors.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(BayanColors.primary.opacity(0.08)))
                }
                .onAppear {
                    if settings.autoPronunciationCheck && !autoStarted {
                        autoStarted = true
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            startRecordingImmediately()
                        }
                    }
                }

            case .recording:
                // Compact waveform
                HStack(spacing: 1.5) {
                    ForEach(0..<barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(hasDetectedSpeech ? BayanColors.primary : BayanColors.primary.opacity(0.25))
                            .frame(width: 2.5, height: max(2, audioLevels[i] * 28))
                    }
                }
                .frame(height: 28)
                .onAppear { startMetering() }
                .onDisappear { stopMetering() }

            case .processing:
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(height: 28)

            case .result(let correct, let transcription):
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                        Text(correct ? "Excellent!" : "Not quite")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                    }

                    if !correct && !transcription.isEmpty {
                        Text("Heard: \(transcription)")
                            .font(.system(size: 10))
                            .foregroundStyle(BayanColors.textSecondary)

                        Button {
                            checker.reset()
                            startRecordingImmediately()
                        } label: {
                            Text("Try Again")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(BayanColors.primary)
                        }
                    }
                }
                .onAppear {
                    correct ? Haptics.success() : Haptics.medium()
                    if correct {
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            checker.reset()
                        }
                    }
                }

            case .error:
                Button {
                    checker.reset()
                } label: {
                    Text("Retry")
                        .font(.system(size: 11))
                        .foregroundStyle(BayanColors.textSecondary)
                }
            }
        }
        .transaction { $0.animation = nil } // Kill parent animation to prevent glitchy redraws
    }

    // MARK: - Instant Recording

    private func startRecordingImmediately() {
        // Model is preloaded — start recording NOW
        if checker.isModelLoaded {
            silenceFrames = 0
            hasDetectedSpeech = false
            audioLevels = Array(repeating: 0.03, count: barCount)
            checker.startRecording()
        } else {
            // Fallback: load then record
            Task {
                await checker.loadModel()
                guard checker.isModelLoaded else { return }
                checker.startRecording()
            }
        }
    }

    // MARK: - Audio Metering + VAD

    private func startMetering() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            guard let recorder = checker.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0) // dB: -160 to 0
            // Aggressive scaling: map -50..0 dB to 0..1
            let normalized = max(0, (power + 50) / 50)
            let level = pow(normalized, 0.6) // Compress dynamics so quiet sounds still show

            Task { @MainActor in
                var levels = Array(audioLevels.dropFirst())
                levels.append(CGFloat(max(level, 0.04)))
                audioLevels = levels

                if level > 0.15 { // Speech detected
                    hasDetectedSpeech = true
                    silenceFrames = 0
                } else if hasDetectedSpeech {
                    silenceFrames += 1
                    if silenceFrames >= silenceFramesNeeded {
                        stopMetering()
                        Task {
                            await checker.stopRecording(expectedArabic: expectedArabic)
                        }
                    }
                }
            }
        }

        // Hard ceiling 5s
        Task {
            try? await Task.sleep(for: .seconds(5))
            if case .recording = checker.state {
                stopMetering()
                await checker.stopRecording(expectedArabic: expectedArabic)
            }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
}
