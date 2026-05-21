import AVFoundation
import SwiftUI

/// Pronunciation practice button with live waveform and VAD.
struct PronunciationButton: View {
    let expectedArabic: String
    @Environment(SettingsManager.self) private var settings
    @Environment(AudioPlaybackManager.self) private var audioManager
    @State private var audioLevels: [CGFloat] = Array(repeating: 0.03, count: 20)
    @State private var meterTimer: Timer?
    @State private var silenceFrames = 0
    @State private var hasDetectedSpeech = false
    @State private var speechStartTime: Date?
    @State private var autoStarted = false

    private var checker: PronunciationChecker {
        SharedPronunciationChecker.checker
    }

    // Auto-stop after sustained silence. Bumped from 0.8s → 1.8s because
    // Quranic recitation naturally has pauses (breath, tajweed elongation
    // mid-word, end-of-ayah pauses) that aren't end-of-utterance. The old
    // threshold cut users off mid-recitation when they paused for a
    // single mad. ~1.8s is long enough that only a true stop triggers it.
    private let silenceFramesNeeded = 45  // ~1.8s silence after speech
    private let barCount = 20

    /// Size of the big circular mic button. Bumped up from the prior
    /// 12-pt capsule pill — the small target was hard to hit and not
    /// obviously the primary action.
    private let micDiameter: CGFloat = 72

    var body: some View {
        Group {
            switch checker.state {
            case .idle:
                micCircle(filled: false) {
                    Haptics.medium()
                    startRecording()
                }
                .onAppear {
                    if settings.autoPronunciationCheck && !autoStarted {
                        autoStarted = true
                        Task {
                            try? await Task.sleep(for: .milliseconds(200))
                            startRecording()
                        }
                    }
                }

            case .loading:
                micCircle(filled: false) {
                    Haptics.medium()
                    startRecording()
                }

            case .recording:
                VStack(spacing: 8) {
                    Button {
                        // Tap-to-stop: commit recording immediately,
                        // useful for one-word prompts where the user
                        // doesn't want to wait for VAD silence.
                        Haptics.light()
                        stopMetering()
                        Task {
                            let trimStart = speechStartTime.map { checker.recordingStartTime?.distance(to: $0) ?? 0 } ?? 0
                            await checker.stopRecording(
                                expectedArabic: expectedArabic,
                                trimStartSeconds: max(0, trimStart - 0.1)
                            )
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(AyyatColors.primary)
                                .frame(width: micDiameter, height: micDiameter)
                                .shadow(color: AyyatColors.primary.opacity(0.35), radius: 8, x: 0, y: 2)
                            HStack(spacing: 2) {
                                let visBars = 10
                                let suffix = audioLevels.suffix(visBars)
                                ForEach(Array(suffix.enumerated()), id: \.offset) { _, level in
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(.white.opacity(hasDetectedSpeech ? 1.0 : 0.55))
                                        .frame(width: 2.5, height: max(4, level * 30))
                                }
                            }
                            .frame(maxWidth: micDiameter - 16)
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Text(hasDetectedSpeech ? "Tap to stop" : "Speak now")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AyyatColors.textSecondary)
                }
                .onAppear { startMetering() }
                .onDisappear { stopMetering() }

            case .processing:
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(AyyatColors.primary.opacity(0.15))
                            .frame(width: micDiameter, height: micDiameter)
                        ProgressView()
                            .tint(AyyatColors.primary)
                            .scaleEffect(1.1)
                    }
                    Text("Transcribing…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AyyatColors.textSecondary)
                }

            case .result(let correct, let transcription):
                VStack(spacing: 6) {
                    // Result header
                    HStack(spacing: 4) {
                        Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(correct ? AyyatColors.mastered : AyyatColors.learning)
                        Text(correct ? "Excellent!" : "Not quite")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(correct ? AyyatColors.mastered : AyyatColors.learning)
                    }

                    // Show what was heard — only on incorrect results.
                    // On "Excellent!" we don't want to show the
                    // transcription (it can be slightly different from the
                    // expected word due to diacritic variation and just
                    // distracts from the celebration).
                    if !correct, !transcription.isEmpty {
                        HStack(spacing: 4) {
                            Text("Heard:")
                                .font(.system(size: 10))
                                .foregroundStyle(AyyatColors.textSecondary)
                            Text(transcription)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AyyatColors.learning)
                        }
                    }

                    // Playback & action buttons
                    HStack(spacing: 12) {
                        // Play recording button — only on incorrect results.
                        // Correct = celebration; no reason to play back.
                        if !correct, checker.lastRecordingData != nil {
                            Button {
                                if checker.isPlayingRecording {
                                    checker.stopPlayback()
                                } else {
                                    checker.playRecording()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: checker.isPlayingRecording ? "stop.fill" : "play.fill")
                                        .font(.system(size: 10))
                                    Text(checker.isPlayingRecording ? "Stop" : "Play")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(AyyatColors.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(AyyatColors.primary.opacity(0.1)))
                            }
                        }

                        // Try again button (only for incorrect)
                        if !correct {
                            Button {
                                checker.stopPlayback()
                                // CRITICAL: reset ALL VAD state, including
                                // speechStartTime. Without this the noise-
                                // resilient cap would fire instantly off the
                                // stale timestamp from the prior attempt
                                // and the new recording would record ~100 ms
                                // before being stopped, yielding a 0-byte
                                // audio file that crashes the ASR engines.
                                silenceFrames = 0
                                hasDetectedSpeech = false
                                speechStartTime = nil
                                audioLevels = Array(repeating: 0.03, count: barCount)
                                checker.startRecording()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 10))
                                    Text("Retry")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(AyyatColors.primary))
                            }
                        }
                    }

                    // Playback progress indicator
                    if checker.isPlayingRecording {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(AyyatColors.primary.opacity(0.2))
                                    .frame(height: 3)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(AyyatColors.primary)
                                    .frame(width: geo.size.width * checker.playbackProgress, height: 3)
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                    }
                }
                .onAppear {
                    // Distinct haptic patterns so the user can tell the
                    // verdict before reading: success "rrrr-rrr" double
                    // pulse vs error "rr-rr-rr" triple-bump.
                    correct ? Haptics.success() : Haptics.error()
                    if correct {
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            checker.reset()
                        }
                    }
                }
                .onDisappear {
                    checker.stopPlayback()
                }

            case .error:
                Button {
                    checker.reset()
                } label: {
                    Text("Retry")
                        .font(.system(size: 11))
                        .foregroundStyle(AyyatColors.textSecondary)
                }
            }
        }
        .transaction { $0.animation = nil }
    }

    // MARK: - Recording

    private func startRecording() {
        // Reset VAD state so leftover values from a previous attempt don't
        // trigger the noise-resilient cap immediately.
        silenceFrames = 0
        hasDetectedSpeech = false
        speechStartTime = nil
        audioLevels = Array(repeating: 0.03, count: barCount)

        // Stop any active chapter playback before grabbing the mic.
        // Without this, the audio session is mid-flight between
        // `.playback` and `.record` and AVAudioRecorder occasionally
        // fails to arm (silent recording / "audio failed" error). The
        // user perceives this as "transcribe bugs out when audio is
        // playing".
        if audioManager.isPlaying {
            audioManager.pause()
        }

        checker.startRecording()
    }

    // MARK: - Audio Metering + VAD

    private func startMetering() {
        let expected = expectedArabic
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
            Task { @MainActor [self] in
                guard let recorder = checker.audioRecorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                let normalized = max(0, (power + 50) / 50)
                let level = pow(normalized, 0.6)

                var levels = Array(audioLevels.dropFirst())
                levels.append(CGFloat(max(level, 0.04)))
                audioLevels = levels

                if level > 0.15 {
                    if !hasDetectedSpeech {
                        speechStartTime = Date()
                    }
                    hasDetectedSpeech = true
                    silenceFrames = 0
                } else if hasDetectedSpeech {
                    silenceFrames += 1
                    if silenceFrames >= silenceFramesNeeded {
                        stopMetering()
                        // Calculate how long before speech started (to trim silence)
                        let trimStart = speechStartTime.map { checker.recordingStartTime?.distance(to: $0) ?? 0 } ?? 0
                        await checker.stopRecording(expectedArabic: expected, trimStartSeconds: max(0, trimStart - 0.1))
                        return
                    }
                }

                // Noise-resilient cap: if VAD detected speech but never
                // detected silence (e.g. fan / room noise keeps the mic
                // level above threshold), force-stop 3s after speech
                // started. For one-word pronunciation prompts, 3s is
                // already more than the longest Arabic word.
                if let start = speechStartTime,
                   Date().timeIntervalSince(start) >= 3.0,
                   case .recording = checker.state {
                    dlog("[ayyat] Noise lock — 3s since speech start, stopping")
                    stopMetering()
                    let trimStart = checker.recordingStartTime?.distance(to: start) ?? 0
                    await checker.stopRecording(expectedArabic: expected, trimStartSeconds: max(0, trimStart - 0.1))
                }
            }
        }

        // No-speech ceiling: if VAD never detected any speech, give up
        // after 3 s. The fallback below (21 more s = 24 s total) is the
        // ultimate guard for runaway sessions.
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .recording = checker.state, !hasDetectedSpeech {
                dlog("[ayyat] No speech detected in first 3s — stopping")
                stopMetering()
                await checker.stopRecording(expectedArabic: expectedArabic)
                return
            }
            try? await Task.sleep(for: .seconds(21))   // 3 + 21 = 24
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

    // MARK: - UI helpers

    /// Big round mic button. `filled = true` for the bold filled style
    /// (used during pulsing / active states); false for the tinted-glass
    /// idle style. Includes the "Say This Word" caption underneath so
    /// users know what to do without taking up extra horizontal space.
    @ViewBuilder
    private func micCircle(filled: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(filled ? AyyatColors.primary : AyyatColors.primary.opacity(0.12))
                        .frame(width: micDiameter, height: micDiameter)
                        .overlay(
                            Circle()
                                .stroke(AyyatColors.primary.opacity(filled ? 0 : 0.25), lineWidth: 1)
                        )
                        .shadow(color: filled ? AyyatColors.primary.opacity(0.3) : .black.opacity(0.04),
                                radius: filled ? 8 : 3, x: 0, y: 2)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(filled ? .white : AyyatColors.primary)
                }
            }
            .buttonStyle(.plain)
            Text("Say This Word")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AyyatColors.textSecondary)
        }
    }
}
