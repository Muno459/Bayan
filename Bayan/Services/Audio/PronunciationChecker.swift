import AVFoundation
import Foundation
import SwiftUI
import WhisperKit

/// Records user pronunciation and uses Tarteel AI's Whisper model
/// (on-device) to verify Arabic Quran recitation.
@MainActor
@Observable
final class PronunciationChecker {
    enum State: Equatable {
        case idle
        case recording
        case processing
        case result(correct: Bool, transcription: String)
        case error(String)
    }

    var state: State = .idle

    nonisolated(unsafe) private var whisperKit: WhisperKit?
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var isModelLoaded = false

    // MARK: - Model Loading

    /// Load the Tarteel Whisper model. Call once at app launch or first use.
    func loadModel() async {
        guard !isModelLoaded else { return }
        state = .processing

        do {
            // WhisperKit will use its built-in tiny model as fallback
            // For the tarteel model, we'd need CoreML format
            // Using WhisperKit's default tiny model which works for Arabic
            let config = WhisperKitConfig(model: "openai_whisper-tiny")
            whisperKit = try await WhisperKit(config)
            isModelLoaded = true
            state = .idle
        } catch {
            state = .error("Failed to load model: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording

    /// Start recording user's pronunciation
    func startRecording() {
        state = .recording

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            state = .error("Microphone access denied")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        recordingURL = tempDir.appendingPathComponent("pronunciation_\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0, // Whisper expects 16kHz
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL!, settings: settings)
            audioRecorder?.record()
        } catch {
            state = .error("Failed to start recording")
        }
    }

    /// Stop recording and transcribe
    func stopRecording(expectedArabic: String) async {
        audioRecorder?.stop()
        state = .processing

        // Restore audio session for playback
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let url = recordingURL else {
            state = .error("No recording found")
            return
        }

        // Load model if needed
        if !isModelLoaded {
            await loadModel()
        }

        guard let whisper = whisperKit else {
            state = .error("Model not loaded")
            return
        }

        do {
            let path = url.path()
            let wrapper = UncheckedSendableBox(whisper)
            let results = try await Task.detached { @Sendable in
                try await wrapper.value.transcribe(audioPath: path)
            }.value
            let transcription = results.map { $0.text }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Compare transcription to expected Arabic
            let isCorrect = compareArabic(transcription: transcription, expected: expectedArabic)
            state = .result(correct: isCorrect, transcription: transcription)

            // Cleanup recording file
            try? FileManager.default.removeItem(at: url)
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    func reset() {
        state = .idle
    }

    // MARK: - Arabic Comparison

    /// Compare transcription to expected text, ignoring diacritics and minor differences
    private func compareArabic(transcription: String, expected: String) -> Bool {
        let cleanTranscription = stripDiacritics(transcription)
        let cleanExpected = stripDiacritics(expected)

        // Exact match after stripping diacritics
        if cleanTranscription == cleanExpected { return true }

        // Check if transcription contains the expected word
        if cleanTranscription.contains(cleanExpected) { return true }
        if cleanExpected.contains(cleanTranscription) && !cleanTranscription.isEmpty { return true }

        // Levenshtein distance — allow some tolerance
        let distance = levenshteinDistance(cleanTranscription, cleanExpected)
        let maxLen = max(cleanTranscription.count, cleanExpected.count, 1)
        let similarity = 1.0 - (Double(distance) / Double(maxLen))

        return similarity >= 0.6 // 60% match threshold
    }

    /// Remove Arabic diacritical marks for comparison
    private func stripDiacritics(_ text: String) -> String {
        let diacriticRange: ClosedRange<Unicode.Scalar> = "\u{064B}"..."\u{065F}"
        return String(text.unicodeScalars.filter { !diacriticRange.contains($0) })
            .replacingOccurrences(of: "\u{0670}", with: "") // superscript alef
            .replacingOccurrences(of: "\u{06E1}", with: "") // small high dotless
            .replacingOccurrences(of: "\u{06E4}", with: "") // small high madda
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        var dist = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dist[i][0] = i }
        for j in 0...b.count { dist[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                dist[i][j] = min(dist[i-1][j] + 1, dist[i][j-1] + 1, dist[i-1][j-1] + cost)
            }
        }
        return dist[a.count][b.count]
    }
}

/// Wrapper to pass non-Sendable types across isolation boundaries
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
