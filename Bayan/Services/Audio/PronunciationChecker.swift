import AVFoundation
import CoreML
import Foundation
import SwiftUI

/// On-device Quranic Arabic pronunciation checker using Tarteel AI's
/// Whisper model converted to CoreML. Records user audio, runs mel
/// spectrogram + encoder + decoder natively, compares transcription
/// to expected Arabic text.
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

    private var encoder: MLModel?
    private var decoder: MLModel?
    private var vocab: [String: Int] = [:]
    private var reverseVocab: [Int: String] = [:]
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var isModelLoaded = false

    // Whisper constants
    private let sampleRate = 16000
    private let nMels = 80
    private let nFrames = 3000 // 30 seconds
    private let sotToken = 50258
    private let eotToken = 50257
    private let langToken = 50272 // Arabic
    private let transcribeToken = 50359
    private let maxTokens = 32

    // MARK: - Model Loading

    func loadModel() async {
        guard !isModelLoaded else { return }
        state = .loading

        do {
            // Load encoder
            guard let encoderURL = Bundle.main.url(forResource: "TarteelEncoder", withExtension: "mlmodelc")
                    ?? compiledModelURL(for: "TarteelEncoder") else {
                state = .error("Encoder model not found")
                return
            }
            encoder = try MLModel(contentsOf: encoderURL)

            // Load decoder
            guard let decoderURL = Bundle.main.url(forResource: "TarteelDecoder", withExtension: "mlmodelc")
                    ?? compiledModelURL(for: "TarteelDecoder") else {
                state = .error("Decoder model not found")
                return
            }
            decoder = try MLModel(contentsOf: decoderURL)

            // Load vocab
            if let vocabURL = Bundle.main.url(forResource: "tarteel_vocab", withExtension: "json"),
               let data = try? Data(contentsOf: vocabURL),
               let v = try? JSONDecoder().decode([String: Int].self, from: data) {
                vocab = v
                reverseVocab = Dictionary(uniqueKeysWithValues: v.map { ($1, $0) })
            }

            isModelLoaded = true
            state = .idle
        } catch {
            state = .error("Model load failed: \(error.localizedDescription)")
        }
    }

    /// Compile .mlpackage to .mlmodelc if needed
    private func compiledModelURL(for name: String) -> URL? {
        guard let packageURL = Bundle.main.url(forResource: name, withExtension: "mlpackage") else {
            return nil
        }
        do {
            let compiled = try MLModel.compileModel(at: packageURL)
            return compiled
        } catch {
            return nil
        }
    }

    // MARK: - Recording

    func startRecording() {
        state = .recording

        // Check mic permission first
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            state = .error("Microphone access denied. Enable in Settings.")
            return
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.startRecording()
                    } else {
                        self?.state = .error("Microphone access required")
                    }
                }
            }
            return
        case .granted:
            break
        @unknown default:
            break
        }

        let session = AVAudioSession.sharedInstance()
        do {
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
            AVSampleRateKey: Float(sampleRate),
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

        guard encoder != nil, decoder != nil else {
            state = .error("Model not ready")
            return
        }

        do {
            let audio = try loadAudio(url: url)
            let mel = MelSpectrogram.compute(audio: audio)
            let encoderOutput = try runEncoder(mel: mel)
            let transcription = try runDecoder(encoderOutput: encoderOutput)
            let isCorrect = compareArabic(transcription: transcription, expected: expectedArabic)
            state = .result(correct: isCorrect, transcription: transcription)
            try? FileManager.default.removeItem(at: url)
        } catch {
            state = .error("Processing failed")
        }
    }

    func reset() {
        state = .idle
    }

    // MARK: - Audio Processing

    private func loadAudio(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        try file.read(into: buffer)
        let ptr = buffer.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
    }

    // MARK: - Model Inference

    private func runEncoder(mel: [Float]) throws -> MLMultiArray {
        guard let enc = encoder else { throw NSError(domain: "Bayan", code: 1) }

        let input = try MLMultiArray(shape: [1, NSNumber(value: nMels), NSNumber(value: nFrames)], dataType: .float16)
        for i in 0..<mel.count {
            input[i] = NSNumber(value: mel[i])
        }

        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input_features": input])
        let result = try enc.prediction(from: inputFeatures)
        guard let output = result.featureValue(for: "encoder_output")?.multiArrayValue else {
            throw NSError(domain: "Bayan", code: 2)
        }
        return output
    }

    private func runDecoder(encoderOutput: MLMultiArray) throws -> String {
        guard let dec = decoder else { throw NSError(domain: "Bayan", code: 3) }

        // Start with <|startoftranscript|> <|ar|> <|transcribe|>
        var tokens = [sotToken, langToken, transcribeToken]
        var outputText = ""

        for _ in 0..<maxTokens {
            let inputIds = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
            for (i, t) in tokens.enumerated() {
                inputIds[i] = NSNumber(value: t)
            }

            let features = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": inputIds,
                "encoder_output": encoderOutput,
            ])

            let result = try dec.prediction(from: features)
            guard let logits = result.featureValue(for: "logits")?.multiArrayValue else { break }

            // Get the last token's logits and find argmax
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
                // Clean up Whisper's byte-level BPE encoding
                let cleaned = word
                    .replacingOccurrences(of: "Ġ", with: " ")
                    .replacingOccurrences(of: "▁", with: " ")
                outputText += cleaned
            }
        }

        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Arabic Comparison

    private func compareArabic(transcription: String, expected: String) -> Bool {
        let clean1 = stripDiacritics(transcription)
        let clean2 = stripDiacritics(expected)

        if clean1 == clean2 { return true }
        if clean1.contains(clean2) || clean2.contains(clean1) && !clean1.isEmpty { return true }

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
