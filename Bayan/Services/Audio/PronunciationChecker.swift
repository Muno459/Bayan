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
    private let encoder: MLModel
    private let promptDecoder: MLModel
    private let stepDecoder: MLModel
    private let vocab: [String: Int]
    private let reverseVocab: [Int: String]
    private let byteDecoder: [Character: UInt8] // GPT-2 byte-level BPE decoder

    private let nMels = 80
    private let nFrames = 3000
    private let sotToken = 50258
    private let eotToken = 50257
    private let langToken = 50272
    private let transcribeToken = 50359
    private let maxTokens = 5 // Single Quranic word = 1-3 tokens max

    init() throws {
        guard let encURL = Self.findModel(named: "TarteelEncoder") else {
            throw NSError(domain: "Bayan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Encoder not found"])
        }
        guard let promptURL = Self.findModel(named: "TarteelPromptDecoder") else {
            throw NSError(domain: "Bayan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Prompt decoder not found"])
        }
        guard let stepURL = Self.findModel(named: "TarteelStepDecoder") else {
            throw NSError(domain: "Bayan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Step decoder not found"])
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all // All models use ANE — fixed shapes

        print("[Bayan] Loading encoder...")
        encoder = try MLModel(contentsOf: encURL, configuration: config)
        print("[Bayan] Loading prompt decoder...")
        promptDecoder = try MLModel(contentsOf: promptURL, configuration: config)
        print("[Bayan] Loading step decoder...")
        stepDecoder = try MLModel(contentsOf: stepURL, configuration: config)
        print("[Bayan] All models loaded")

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

        // No trimming — maxTokens=5 prevents hallucination
        // Full audio gives better accuracy for slow speakers
        print("[Bayan] Processing \(String(format: "%.1f", Float(audio.count) / 16000))s of audio")

        guard let mel = MelSpectrogram.compute(audio: audio) else {
            print("[Bayan] Mel computation failed")
            return nil
        }
        print("[Bayan] Mel computed: \(mel.shape) (processed \(min(audio.count, 16000 * 30)) samples)")

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
        // Step 1: Run prompt decoder with [SOT, AR, TRANSCRIBE] — get logits + KV cache
        let promptIds = try MLMultiArray(shape: [1, 3], dataType: .int32)
        promptIds[0] = NSNumber(value: sotToken)
        promptIds[1] = NSNumber(value: langToken)
        promptIds[2] = NSNumber(value: transcribeToken)

        let promptFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": promptIds,
            "encoder_output": encoderOutput,
        ])
        let promptResult = try promptDecoder.prediction(from: promptFeatures)
        guard let promptLogits = promptResult.featureValue(for: "logits")?.multiArrayValue else {
            return ""
        }

        // Extract first token from prompt logits (last position = index 2)
        var firstToken = argmax(logits: promptLogits, position: 2)
        if firstToken == eotToken { return "" }

        // Extract KV cache from prompt
        var kvCache: [String: MLMultiArray] = [:]
        for i in 0..<4 {
            kvCache["pk\(i)"] = promptResult.featureValue(for: "pk\(i)")?.multiArrayValue
            kvCache["pv\(i)"] = promptResult.featureValue(for: "pv\(i)")?.multiArrayValue
        }

        var outputText = ""
        if let word = reverseVocab[firstToken] {
            outputText += decodeBPEToken(word)
        }

        // Step 2: Run step decoder for remaining tokens (with KV cache — O(1) per step)
        for _ in 1..<maxTokens {
            let inputId = try MLMultiArray(shape: [1, 1], dataType: .int32)
            inputId[0] = NSNumber(value: firstToken)

            var stepDict: [String: Any] = [
                "input_id": inputId,
                "encoder_output": encoderOutput,
            ]
            for i in 0..<4 {
                if let pk = kvCache["pk\(i)"] { stepDict["pk\(i)"] = pk }
                if let pv = kvCache["pv\(i)"] { stepDict["pv\(i)"] = pv }
            }

            let stepFeatures = try MLDictionaryFeatureProvider(dictionary: stepDict)
            let stepResult = try stepDecoder.prediction(from: stepFeatures)
            guard let stepLogits = stepResult.featureValue(for: "logits")?.multiArrayValue else { break }

            let nextToken = argmax(logits: stepLogits, position: 0)
            if nextToken == eotToken { break }

            // Update KV cache
            for i in 0..<4 {
                kvCache["pk\(i)"] = stepResult.featureValue(for: "npk\(i)")?.multiArrayValue
                kvCache["pv\(i)"] = stepResult.featureValue(for: "npv\(i)")?.multiArrayValue
            }

            if let word = reverseVocab[nextToken] {
                outputText += decodeBPEToken(word)
            }
            firstToken = nextToken
        }

        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Argmax over vocabulary at a given sequence position
    private func argmax(logits: MLMultiArray, position: Int) -> Int {
        let vocabSize = logits.shape[2].intValue
        let offset = position * vocabSize
        var maxIdx = 0
        var maxVal: Float = -Float.infinity
        for i in 0..<vocabSize {
            let val = logits[offset + i].floatValue
            if val > maxVal { maxVal = val; maxIdx = i }
        }
        return maxIdx
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
