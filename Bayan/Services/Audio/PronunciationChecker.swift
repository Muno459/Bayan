import AVFoundation
import CoreML
import Foundation
import SwiftUI

/// On-device Quranic Arabic pronunciation checker.
/// All heavy work (model loading, mel spectrogram, inference) runs off main thread.
@MainActor
@Observable
final class PronunciationChecker {
    enum State: Equatable {
        case idle
        case loading
        case recording
        case processing
        case result(correct: Bool, transcription: String)
        case error(String)
    }

    var state: State = .idle

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var inferenceEngine: PronunciationInferenceEngine?
    private var isModelLoaded = false

    // MARK: - Model Loading (background)

    func loadModel() async {
        guard !isModelLoaded else { return }
        state = .loading

        do {
            inferenceEngine = try await Task.detached(priority: .userInitiated) {
                try PronunciationInferenceEngine()
            }.value
            isModelLoaded = true
            state = .idle
        } catch {
            state = .error("Model loading — try again")
        }
    }

    /// Pre-warm the model in the background (call on app launch)
    func preloadModel() {
        guard !isModelLoaded else { return }
        Task.detached(priority: .background) { [weak self] in
            let engine = try? PronunciationInferenceEngine()
            await MainActor.run {
                self?.inferenceEngine = engine
                self?.isModelLoaded = engine != nil
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        state = .recording

        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            state = .error("Microphone access denied. Enable in Settings.")
            return
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.startRecording() }
                    else { self?.state = .error("Microphone access required") }
                }
            }
            return
        case .granted: break
        @unknown default: break
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            state = .error("Could not access microphone")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        recordingURL = tempDir.appendingPathComponent("pron_\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Float(16000),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL!, settings: settings)
            audioRecorder?.record()
        } catch {
            state = .error("Recording failed")
        }
    }

    func stopRecording(expectedArabic: String) async {
        audioRecorder?.stop()
        state = .processing

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let url = recordingURL else {
            state = .error("No recording")
            return
        }

        if !isModelLoaded { await loadModel() }

        guard let engine = inferenceEngine else {
            state = .error("Model not ready")
            return
        }

        // ALL heavy work runs off main thread with timeout
        let expected = expectedArabic
        let inferenceTask = Task.detached(priority: .userInitiated) { () -> (Bool, String)? in
            do {
                return try engine.processRecording(url: url, expectedArabic: expected)
            } catch {
                return nil
            }
        }

        // Race inference against a 15-second timeout
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(15))
            return nil as (Bool, String)?
        }

        let result: (Bool, String)?
        if let inferenceResult = await inferenceTask.value {
            timeoutTask.cancel()
            result = inferenceResult
        } else {
            result = nil
        }

        try? FileManager.default.removeItem(at: url)

        if let (correct, transcription) = result {
            state = .result(correct: correct, transcription: transcription)
        } else if case .processing = state {
            // Still in processing after timeout or failure
            state = .error("Could not process — try on a real device")
        }
    }

    func reset() {
        state = .idle
    }
}

// MARK: - Background Inference Engine (not @MainActor)

/// Handles all heavy computation off the main thread.
/// Thread-safe: all state is internal, no shared mutable state.
final class PronunciationInferenceEngine: @unchecked Sendable {
    private let encoder: MLModel
    private let decoder: MLModel
    private let vocab: [String: Int]
    private let reverseVocab: [Int: String]

    private let nMels = 80
    private let nFrames = 3000
    private let sotToken = 50258
    private let eotToken = 50257
    private let langToken = 50272
    private let transcribeToken = 50359
    private let maxTokens = 32

    init() throws {
        // Load models
        guard let encoderURL = Bundle.main.url(forResource: "TarteelEncoder", withExtension: "mlmodelc")
                ?? Self.compileModel(named: "TarteelEncoder"),
              let decoderURL = Bundle.main.url(forResource: "TarteelDecoder", withExtension: "mlmodelc")
                ?? Self.compileModel(named: "TarteelDecoder") else {
            throw NSError(domain: "Bayan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not found"])
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        encoder = try MLModel(contentsOf: encoderURL, configuration: config)
        decoder = try MLModel(contentsOf: decoderURL, configuration: config)

        // Load vocab
        if let vocabURL = Bundle.main.url(forResource: "tarteel_vocab", withExtension: "json"),
           let data = try? Data(contentsOf: vocabURL),
           let v = try? JSONDecoder().decode([String: Int].self, from: data) {
            vocab = v
            reverseVocab = Dictionary(uniqueKeysWithValues: v.map { ($1, $0) })
        } else {
            vocab = [:]
            reverseVocab = [:]
        }
    }

    private static func compileModel(named name: String) -> URL? {
        guard let packageURL = Bundle.main.url(forResource: name, withExtension: "mlpackage") else { return nil }
        return try? MLModel.compileModel(at: packageURL)
    }

    /// Process a recording: load audio, compute mel, run encoder+decoder, compare.
    /// Returns nil if silence or non-Arabic detected.
    func processRecording(url: URL, expectedArabic: String) throws -> (Bool, String)? {
        let audio = try loadAudio(url: url)

        // Silence check
        let maxAmplitude = audio.map { abs($0) }.max() ?? 0
        if maxAmplitude < 0.01 { return nil }

        let mel = MelSpectrogram.compute(audio: audio)
        let encoderOutput = try runEncoder(mel: mel)
        let transcription = try runDecoder(encoderOutput: encoderOutput)

        // Filter non-Arabic transcriptions
        let hasArabic = transcription.unicodeScalars.contains { $0.value >= 0x0600 && $0.value <= 0x06FF }
        if !hasArabic && !transcription.isEmpty { return nil }

        let correct = compareArabic(transcription: transcription, expected: expectedArabic)
        return (correct, transcription)
    }

    // MARK: - Audio

    private func loadAudio(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
            throw NSError(domain: "Bayan", code: 2)
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "Bayan", code: 3)
        }
        try file.read(into: buffer)
        guard let ptr = buffer.floatChannelData?[0] else {
            throw NSError(domain: "Bayan", code: 4)
        }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
    }

    // MARK: - Encoder

    private func runEncoder(mel: [Float]) throws -> MLMultiArray {
        let input = try MLMultiArray(shape: [1, NSNumber(value: nMels), NSNumber(value: nFrames)], dataType: .float16)
        for i in 0..<min(mel.count, nMels * nFrames) {
            input[i] = NSNumber(value: mel[i])
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["input_features": input])
        let result = try encoder.prediction(from: features)
        guard let output = result.featureValue(for: "encoder_output")?.multiArrayValue else {
            throw NSError(domain: "Bayan", code: 5)
        }
        return output
    }

    // MARK: - Decoder

    private func runDecoder(encoderOutput: MLMultiArray) throws -> String {
        var tokens = [sotToken, langToken, transcribeToken]
        var outputText = ""

        for _ in 0..<maxTokens {
            let inputIds = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
            for (i, t) in tokens.enumerated() { inputIds[i] = NSNumber(value: t) }

            let features = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": inputIds,
                "encoder_output": encoderOutput,
            ])
            let result = try decoder.prediction(from: features)
            guard let logits = result.featureValue(for: "logits")?.multiArrayValue else { break }

            let vocabSize = logits.shape[2].intValue
            let offset = (tokens.count - 1) * vocabSize
            var maxIdx = 0
            var maxVal: Float = -Float.infinity
            for i in 0..<vocabSize {
                let val = logits[offset + i].floatValue
                if val > maxVal { maxVal = val; maxIdx = i }
            }

            if maxIdx == eotToken { break }
            tokens.append(maxIdx)

            if let word = reverseVocab[maxIdx] {
                outputText += word
                    .replacingOccurrences(of: "Ġ", with: " ")
                    .replacingOccurrences(of: "▁", with: " ")
            }
        }

        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Comparison

    private func compareArabic(transcription: String, expected: String) -> Bool {
        let clean1 = stripDiacritics(transcription)
        let clean2 = stripDiacritics(expected)
        if clean1 == clean2 { return true }
        if !clean1.isEmpty && (clean1.contains(clean2) || clean2.contains(clean1)) { return true }
        let dist = levenshteinDistance(clean1, clean2)
        let maxLen = max(clean1.count, clean2.count, 1)
        return (1.0 - Double(dist) / Double(maxLen)) >= 0.6
    }

    private func stripDiacritics(_ text: String) -> String {
        let range: ClosedRange<Unicode.Scalar> = "\u{064B}"..."\u{065F}"
        return String(text.unicodeScalars.filter { !range.contains($0) })
            .replacingOccurrences(of: "\u{0670}", with: "")
            .replacingOccurrences(of: "\u{06E1}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (a[i-1] == b[j-1] ? 0 : 1))
            }
        }
        return d[a.count][b.count]
    }
}
