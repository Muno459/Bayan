import AVFoundation
import SwiftUI

/// Bleeding-edge pronunciation practice.
/// Auto-detects speech start/end. Live waveform. Fluid result animation.
struct PronunciationButton: View {
    let expectedArabic: String
    @Environment(SettingsManager.self) private var settings
    @State private var checker = PronunciationChecker()
    @State private var autoStarted = false
    @State private var audioLevels: [CGFloat] = Array(repeating: 0.03, count: 24)
    @State private var meterTimer: Timer?
    @State private var silenceFrames = 0
    @State private var hasDetectedSpeech = false

    private let silenceThreshold: Float = 0.008
    private let silenceFramesNeeded = 25 // ~1.25s of silence after speech to auto-stop
    private let barCount = 24

    var body: some View {
        VStack(spacing: 10) {
            switch checker.state {
            case .idle, .loading:
                // Auto-start on appear, or tap to start
                Button {
                    Haptics.medium()
                    startListening()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: checker.state == .loading ? "hourglass" : "mic.fill")
                            .font(.system(size: 14))
                        Text(checker.state == .loading ? "Preparing..." : "Say This Word")
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
                            try? await Task.sleep(for: .milliseconds(600))
                            startListening()
                        }
                    }
                }

            case .recording:
                VStack(spacing: 6) {
                    // Live waveform
                    HStack(spacing: 2) {
                        ForEach(0..<barCount, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(hasDetectedSpeech ? BayanColors.primary : BayanColors.primary.opacity(0.3))
                                .frame(width: 3, height: max(3, audioLevels[i] * 32))
                                .animation(.easeOut(duration: 0.08), value: audioLevels[i])
                        }
                    }
                    .frame(height: 36)

                    Text(hasDetectedSpeech ? "Listening..." : "Speak now")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hasDetectedSpeech ? BayanColors.primary : BayanColors.textSecondary)
                }
                .onAppear { startMetering() }
                .onDisappear { stopMetering() }

            case .processing:
                // Collapse waveform into processing dots
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(BayanColors.primary)
                            .frame(width: 6, height: 6)
                            .offset(y: processingBounce(index: i))
                    }
                }
                .frame(height: 36)

            case .result(let correct, let transcription):
                VStack(spacing: 6) {
                    // Result icon with animation
                    Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)
                        .symbolEffect(.bounce, value: checker.state)

                    Text(correct ? "Excellent!" : "Not quite right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(correct ? BayanColors.mastered : BayanColors.learning)

                    // Show what was heard on failure
                    if !correct && !transcription.isEmpty {
                        HStack(spacing: 3) {
                            Text("Heard:")
                                .font(.system(size: 11))
                                .foregroundStyle(BayanColors.textSecondary)
                            Text(transcription)
                                .font(.system(size: 13))
                                .foregroundStyle(BayanColors.learning)
                        }

                        Button {
                            checker.reset()
                            startListening()
                        } label: {
                            Text("Try Again")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(BayanColors.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(BayanColors.primary.opacity(0.08)))
                        }
                    }
                }
                .onAppear {
                    if correct {
                        Haptics.success()
                        Task {
                            try? await Task.sleep(for: .seconds(2.5))
                            checker.reset()
                        }
                    } else {
                        Haptics.medium()
                    }
                }

            case .error(let msg):
                VStack(spacing: 3) {
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
        .animation(.easeInOut(duration: 0.25), value: checker.state)
    }

    // MARK: - Recording

    private func startListening() {
        Task {
            if !checker.isModelLoaded {
                await checker.loadModel()
            }
            guard checker.isModelLoaded else { return }
            silenceFrames = 0
            hasDetectedSpeech = false
            audioLevels = Array(repeating: 0.03, count: barCount)
            checker.startRecording()
        }
    }

    // MARK: - Audio Metering + Voice Activity Detection

    private func startMetering() {
        checker.audioRecorder?.isMeteringEnabled = true

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard let recorder = checker.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()

            let power = recorder.averagePower(forChannel: 0) // dB, -160 to 0
            let linear = pow(10, power / 20) // Convert to 0-1 linear scale

            // Shift levels left, add new level
            Task { @MainActor in
                var newLevels = Array(audioLevels.dropFirst())
                newLevels.append(CGFloat(max(linear * 2, 0.03)))
                audioLevels = newLevels

                // Voice activity detection
                if linear > silenceThreshold {
                    hasDetectedSpeech = true
                    silenceFrames = 0
                } else if hasDetectedSpeech {
                    silenceFrames += 1
                    if silenceFrames >= silenceFramesNeeded {
                        // Speech ended — auto-stop
                        stopMetering()
                        Task {
                            await checker.stopRecording(expectedArabic: expectedArabic)
                        }
                    }
                }
            }
        }

        // Hard ceiling: 6 seconds max
        Task {
            try? await Task.sleep(for: .seconds(6))
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

    // MARK: - Processing Animation

    @State private var processingPhase: Double = 0

    private func processingBounce(index: Int) -> CGFloat {
        let phase = Date().timeIntervalSinceReferenceDate * 4 + Double(index) * 0.5
        return CGFloat(sin(phase)) * 4
    }
}
