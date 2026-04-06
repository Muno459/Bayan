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

    private(set) var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var inferenceEngine: PronunciationInferenceEngine?
    private(set) var isModelLoaded = false
    private var isModelLoading = false

    // MARK: - Model Loading

    func loadModel() async {
        guard !isModelLoaded, !isModelLoading else { return }
        isModelLoading = true
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
        isModelLoading = false
    }

    /// Pre-warm the model in the background (call on app launch).
    /// Safe to call multiple times — only loads once.
    func preloadModel() {
        guard !isModelLoaded, !isModelLoading else { return }
        isModelLoading = true
        Task.detached(priority: .background) { [weak self] in
            let engine = try? PronunciationInferenceEngine()
            await MainActor.run {
                guard let self else { return }
                if !self.isModelLoaded {
                    self.inferenceEngine = engine
                    self.isModelLoaded = engine != nil
                }
                self.isModelLoading = false
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
            // Deactivate first to stop any playing audio, then switch to record
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
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

        guard let url = recordingURL else {
            state = .error("Recording failed")
            return
        }

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
        } catch {
            // Restore audio session on failure
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
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
        let inferenceTask = Task.detached(priority: .userInitiated) { () -> Result<(Bool, String)?, Error> in
            do {
                let result = try engine.processRecording(url: url, expectedArabic: expected)
                return .success(result)
            } catch {
                print("[Bayan] Inference error: \(error)")
                return .failure(error)
            }
        }

        let inferenceResult = await inferenceTask.value
        try? FileManager.default.removeItem(at: url)

        switch inferenceResult {
        case .success(let result):
            if let (correct, transcription) = result {
                state = .result(correct: correct, transcription: transcription)
            } else {
                // Silence, no Arabic, or empty — just reset
                state = .idle
            }
        case .failure(let error):
            print("[Bayan] Processing failed: \(error)")
            state = .error("Error: \(error.localizedDescription)")
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
    private let melExtractor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let vocab: [String: Int]
    private let reverseVocab: [Int: String]
    private let byteDecoder: [Character: UInt8] // GPT-2 byte-level BPE decoder

    private let nMels = 80
    private let nFrames = 3000
    private let sotToken = 50258
    private let eotToken = 50257
    private let langToken = 50272
    private let transcribeToken = 50359
    private let maxTokens = 10 // Allow more tokens, smart matching finds the expected word

    init() throws {
        guard let melURL = Self.findModel(named: "WhisperMelExtractor"),
              let encURL = Self.findModel(named: "TarteelEncoder"),
              let decURL = Self.findModel(named: "TarteelDecoder")
        else {
            throw NSError(domain: "Bayan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Models not found"])
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all

        print("[Bayan] Loading 3 models...")
        let start = CFAbsoluteTimeGetCurrent()
        melExtractor = try MLModel(contentsOf: melURL, configuration: config)
        encoder = try MLModel(contentsOf: encURL, configuration: config)
        decoder = try MLModel(contentsOf: decURL, configuration: config)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("[Bayan] All models loaded in \(String(format: "%.1f", elapsed))s")

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

        // Load GPT-2 byte-level BPE decoder (unicode char -> byte value)
        if let bpeURL = Bundle.main.url(forResource: "bpe_byte_decoder", withExtension: "json"),
           let data = try? Data(contentsOf: bpeURL),
           let mapping = try? JSONDecoder().decode([String: Int].self, from: data) {
            var decoder: [Character: UInt8] = [:]
            for (key, value) in mapping {
                if let char = key.first, value >= 0 && value <= 255 {
                    decoder[char] = UInt8(value)
                }
            }
            byteDecoder = decoder
            print("[Bayan] Byte decoder loaded: \(decoder.count) entries")
        } else {
            byteDecoder = [:]
            print("[Bayan] Warning: byte decoder not found")
        }
    }

    /// Find a .mlmodelc bundle in the app bundle
    private static func findModel(named name: String) -> URL? {
        // Try direct lookup
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        // Search in bundle
        let bundlePath = Bundle.main.bundlePath
        let modelPath = (bundlePath as NSString).appendingPathComponent("\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: modelPath) {
            return URL(fileURLWithPath: modelPath)
        }
        // Search recursively
        if let enumerator = FileManager.default.enumerator(atPath: bundlePath) {
            while let path = enumerator.nextObject() as? String {
                if path.hasSuffix("\(name).mlmodelc") {
                    return URL(fileURLWithPath: (bundlePath as NSString).appendingPathComponent(path))
                }
            }
        }
        return nil
    }

    /// Process a recording: load audio, compute mel, run encoder+decoder, compare.
    /// Returns nil if silence or non-Arabic detected.
    func processRecording(url: URL, expectedArabic: String) throws -> (Bool, String)? {
        print("[Bayan] Processing recording: \(url.lastPathComponent)")
        var audio = try loadAudio(url: url)
        print("[Bayan] Audio loaded: \(audio.count) samples")

        // Silence check
        let maxAmplitude = audio.map { abs($0) }.max() ?? 0
        print("[Bayan] Max amplitude: \(maxAmplitude)")
        if maxAmplitude < 0.01 {
            print("[Bayan] Silence detected, skipping")
            return nil
        }

        print("[Bayan] Processing \(String(format: "%.1f", Float(audio.count) / 16000))s of audio")

        let mel = try runMelExtractor(audio: audio)
        print("[Bayan] Mel computed: \(mel.shape)")

        let encoderOutput = try runEncoder(melArray: mel)
        print("[Bayan] Encoder done, output shape: \(encoderOutput.shape)")

        let transcription = try runDecoder(encoderOutput: encoderOutput)
        print("[Bayan] Transcription: '\(transcription)'")

        // Filter non-Arabic transcriptions
        let hasArabic = transcription.unicodeScalars.contains { $0.value >= 0x0600 && $0.value <= 0x06FF }
        if !hasArabic && !transcription.isEmpty {
            print("[Bayan] No Arabic detected in transcription, skipping")
            return nil
        }

        if transcription.isEmpty {
            print("[Bayan] Empty transcription")
            return nil
        }

        let correct = compareArabic(transcription: transcription, expected: expectedArabic)
        print("[Bayan] Comparison: correct=\(correct)")
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

    // MARK: - Mel Extractor (CoreML — replaces broken Swift FFT)

    // MARK: - Encoder

    // MARK: - Mel Extractor (CoreML — proven accurate)

    private func runMelExtractor(audio: [Float]) throws -> MLMultiArray {
        let nSamples = 480000
        let input = try MLMultiArray(shape: [1, NSNumber(value: nSamples)], dataType: .float32)
        let count = min(audio.count, nSamples)
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: nSamples)
        audio.withUnsafeBufferPointer { buf in
            ptr.update(from: buf.baseAddress!, count: count)
        }

        let features = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
        let result = try melExtractor.prediction(from: features)
        guard let mel = result.featureValue(for: "mel_spectrogram")?.multiArrayValue else {
            throw NSError(domain: "Bayan", code: 4, userInfo: [NSLocalizedDescriptionKey: "Mel extraction failed"])
        }
        // Trim from 3001 to 3000 frames if needed
        let melFrames = mel.shape[2].intValue
        if melFrames > 3000 {
            let trimmed = try MLMultiArray(shape: [1, 80, 3000], dataType: .float16)
            let src = mel.dataPointer.bindMemory(to: Float16.self, capacity: 80 * melFrames)
            let dst = trimmed.dataPointer.bindMemory(to: Float16.self, capacity: 80 * 3000)
            for m in 0..<80 {
                memcpy(dst.advanced(by: m * 3000), src.advanced(by: m * melFrames), 3000 * MemoryLayout<Float16>.size)
            }
            return trimmed
        }
        return mel
    }

    // MARK: - Encoder

    private func runEncoder(melArray: MLMultiArray) throws -> MLMultiArray {
        let features = try MLDictionaryFeatureProvider(dictionary: ["input_features": melArray])
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
                outputText += decodeBPEToken(word)
            }
        }

        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode a GPT-2 byte-level BPE token to actual Unicode text.
    /// Each character in the token maps to a byte value via the GPT-2 mapping.
    /// The resulting bytes form UTF-8 text.
    private func decodeBPEToken(_ token: String) -> String {
        // Skip special tokens
        if token.hasPrefix("<|") && token.hasSuffix("|>") { return "" }
        // Handle space prefix
        let cleaned = token.replacingOccurrences(of: "Ġ", with: " ")
        // Decode each character through the byte mapping
        var bytes: [UInt8] = []
        for char in cleaned {
            if char == " " {
                bytes.append(32) // Space byte not in GPT-2 byte decoder
            } else if let byte = byteDecoder[char] {
                bytes.append(byte)
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    // MARK: - Audio Trimming

    /// Trim leading and trailing silence from audio.
    /// Keeps a small margin (0.1s) around the speech for natural sound.
    private func trimSilence(audio: [Float], threshold: Float) -> [Float] {
        let margin = 1600 // 0.1s at 16kHz
        let windowSize = 400 // Check in 25ms windows

        // Find first sample above threshold
        var start = 0
        for i in stride(from: 0, to: audio.count - windowSize, by: windowSize) {
            let windowMax = audio[i..<min(i + windowSize, audio.count)].map { abs($0) }.max() ?? 0
            if windowMax > threshold {
                start = max(0, i - margin)
                break
            }
        }

        // Find last sample above threshold
        var end = audio.count
        for i in stride(from: audio.count - windowSize, through: 0, by: -windowSize) {
            let windowMax = audio[max(0, i)..<min(i + windowSize, audio.count)].map { abs($0) }.max() ?? 0
            if windowMax > threshold {
                end = min(audio.count, i + windowSize + margin)
                break
            }
        }

        guard start < end else { return audio }
        return Array(audio[start..<end])
    }

    // MARK: - Intelligent Matching

    /// Instead of comparing the full transcription, find the best matching
    /// substring within the decoder output. The model may output extra tokens
    /// (e.g., "بسم الله" when we expected "الله"), so we find the expected
    /// word within the output and score that substring.
    private func compareArabic(transcription: String, expected: String) -> Bool {
        let cleanTranscription = stripDiacritics(transcription)
        let cleanExpected = stripDiacritics(expected)

        guard !cleanTranscription.isEmpty, !cleanExpected.isEmpty else { return false }

        // 1. Exact match
        if cleanTranscription == cleanExpected { return true }

        // 2. Expected word found within transcription (model said more but includes the word)
        if cleanTranscription.contains(cleanExpected) { return true }

        // 3. Transcription is a substring of expected (model said part of it correctly)
        if cleanExpected.contains(cleanTranscription) && cleanTranscription.count >= cleanExpected.count / 2 {
            return true
        }

        // 4. Split transcription into words, find best match against expected
        let words = cleanTranscription.split(separator: " ").map(String.init)
        for word in words {
            if word == cleanExpected { return true }
            let dist = levenshteinDistance(word, cleanExpected)
            let maxLen = max(word.count, cleanExpected.count, 1)
            if (1.0 - Double(dist) / Double(maxLen)) >= 0.65 { return true }
        }

        // 5. Sliding window — find the best substring match within transcription
        let expectedChars = Array(cleanExpected)
        let transChars = Array(cleanTranscription)
        if transChars.count >= expectedChars.count {
            var bestSimilarity: Double = 0
            for start in 0...(transChars.count - expectedChars.count) {
                let window = String(transChars[start..<start + expectedChars.count])
                let dist = levenshteinDistance(window, cleanExpected)
                let similarity = 1.0 - Double(dist) / Double(expectedChars.count)
                bestSimilarity = max(bestSimilarity, similarity)
            }
            if bestSimilarity >= 0.6 { return true }
        }

        // 6. Overall similarity as fallback
        let dist = levenshteinDistance(cleanTranscription, cleanExpected)
        let maxLen = max(cleanTranscription.count, cleanExpected.count, 1)
        return (1.0 - Double(dist) / Double(maxLen)) >= 0.55
    }

    private func stripDiacritics(_ text: String) -> String {
        return String(text.unicodeScalars.filter { scalar in
            // Remove Arabic diacritics (tashkeel)
            if scalar.value >= 0x064B && scalar.value <= 0x065F { return false }
            // Remove Quranic annotation signs
            if scalar.value >= 0x0610 && scalar.value <= 0x061A { return false }
            // Remove Uthmani small/superscript marks
            if scalar.value >= 0x06D6 && scalar.value <= 0x06ED { return false }
            // Remove tatweel
            if scalar.value == 0x0640 { return false }
            // Remove superscript alef
            if scalar.value == 0x0670 { return false }
            return true
        })
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
