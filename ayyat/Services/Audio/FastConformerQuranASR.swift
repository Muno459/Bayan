import AVFoundation
import CoreML
import Foundation

/// Quranic Arabic ASR using a custom FastConformer-CTC CoreML model.
///
/// Drop-in alternative to `TarteelWhisperKit`. Same public surface — load
/// once, then call `transcribe(samples:)` / `transcribeWithTimestamps(url:)`.
///
/// Pipeline:
///   1. 16 kHz mono PCM samples in.
///   2. `LogMelFeatures` → (1, 80, T) float16 log-mel spectrogram.
///   3. CoreML model → (1, T_out, 1025) frame log-probs.
///   4. Greedy CTC decode: argmax per frame, collapse blanks (id 1024),
///      dedupe consecutive repeats.
///   5. Map token ids → text via `tokens.txt` (SentencePiece `▁` =
///      word-start marker → space).
final class FastConformerQuranASR: @unchecked Sendable {
    /// Frame-level CTC blank token id. Sits one past the last vocab entry
    /// (1024 vocab tokens, 0..1023, blank = 1024).
    private static let blankId = 1024

    private let model: MLModel
    private let vocab: [Int: String]
    private(set) var isUsingANE: Bool

    var isLoaded: Bool { true }
    var isOptimized: Bool { isUsingANE }

    /// Load the CoreML model and token vocab. Throws if either resource
    /// is missing from the app bundle.
    ///
    /// **Important:** Xcode pre-compiles the `.mlpackage` at *build* time
    /// into a `.mlmodelc` directory that ships inside the app bundle.
    /// Calling `MLModel.compileModel(at:)` at runtime would recompile a
    /// source package; pointed at the already-compiled `.mlmodelc` it
    /// errors with `A valid manifest does not exist`. We just load the
    /// pre-compiled directory directly — instant on cached devices,
    /// ~seconds with ANE specialization on first launch.
    init(useANE: Bool = true) async throws {
        let modelURL = try Self.compiledModelURL()
        let config = MLModelConfiguration()
        config.computeUnits = useANE ? .all : .cpuOnly
        // CoreML init reads the weights + spins up ANE specialization
        // (slow first launch, cached thereafter). The caller is expected
        // to run this init from a background-priority Task — see
        // `PronunciationChecker.preloadModel()`.
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
        self.vocab = try Self.loadVocab()
        self.isUsingANE = useANE
    }

    // MARK: - Public API

    /// Transcribe a 16 kHz mono float32 PCM buffer.
    func transcribe(samples: [Float]) async throws -> String {
        let result = try await transcribeFull(samples: samples)
        return result.text
    }

    /// Transcribe an audio file (WAV/M4A/etc). Resamples to 16 kHz mono
    /// using `AVAudioConverter`.
    func transcribe(url: URL) async throws -> String {
        let samples = try loadSamples(from: url)
        return try await transcribe(samples: samples)
    }

    /// Transcribe with word-level start/end timestamps derived from the
    /// CTC alignment. Each contiguous run of frames mapped to the same
    /// emitted token becomes a (start, end) pair in seconds.
    func transcribeWithTimestamps(url: URL) async throws -> TranscriptionWithTimestamps {
        let samples = try loadSamples(from: url)
        let result = try await transcribeFull(samples: samples)
        let duration = Double(samples.count) / Double(LogMelFeatures.sampleRate)
        // Map each word back to its frame range. Words are split on the
        // `▁` (U+2581) prefix in the SentencePiece vocab — same convention
        // librosa / NeMo use.
        var words: [TimestampedWord] = []
        var current = ""
        var startFrame = 0
        for emission in result.emissions {
            let piece = vocab[emission.tokenId] ?? ""
            if piece.hasPrefix("\u{2581}") {
                if !current.isEmpty {
                    let end = emission.frame
                    words.append(timestampedWord(current, startFrame: startFrame, endFrame: end))
                }
                current = String(piece.dropFirst())
                startFrame = emission.frame
            } else {
                current += piece
            }
        }
        if !current.isEmpty {
            // Last word runs to end of audio.
            words.append(timestampedWord(current,
                                         startFrame: startFrame,
                                         endFrame: result.lastFrame))
        }
        return TranscriptionWithTimestamps(text: result.text, words: words, duration: duration)
    }

    // MARK: - Pipeline

    private struct CTCEmission {
        let tokenId: Int
        let frame: Int      // First frame where this emission appeared
    }

    private struct FullResult {
        let text: String
        let emissions: [CTCEmission]
        let lastFrame: Int
    }

    private func transcribeFull(samples: [Float]) async throws -> FullResult {
        let (mel, realFrames) = try LogMelFeatures.compute(samples: samples)

        // Re-exported via the Linux NeMo path with
        // `RelPositionalEncoding.forward` patched to clamp(-2400, 2400)
        // before the `xscale` multiply — prevents the 117k FP16 overflow
        // at /encoder/pos_enc/Mul that NaN'd every prior FP16 export.
        // Fixed input shape (1, 80, 800), Float16, no `length` input
        // (the encoder masks padded frames internally via positional
        // indexing). Runs on ANE.
        let inputs: [String: MLFeatureValue] = [
            "audio_signal": MLFeatureValue(multiArray: mel),
        ]
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        let prediction = try await model.prediction(from: provider)
        guard let logprobs = prediction.featureValue(for: "logprobs")?.multiArrayValue else {
            throw NSError(domain: "FastConformerQuranASR", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing logprobs output"])
        }

        // logprobs shape: (1, 100, 1025). The full 100 frames cover the
        // padded buffer; only the first `realOutputFrames` frames cover
        // real audio. Skipping the rest avoids spurious token emissions
        // from the log-floor-padded silence region.
        let modelOutFrames = logprobs.shape[1].intValue
        let subsample = LogMelFeatures.encoderSubsamplingRatio
        let realOutputFrames = min(
            modelOutFrames,
            (realFrames + subsample - 1) / subsample   // ceil(realFrames / 8)
        )
        let vocabPlusBlank = logprobs.shape[2].intValue
        let stride0 = logprobs.strides[0].intValue
        let stride1 = logprobs.strides[1].intValue
        let stride2 = logprobs.strides[2].intValue

        // Greedy CTC: argmax over vocab per frame, then collapse.
        var emissions: [CTCEmission] = []
        var prevId = -1
        for t in 0..<realOutputFrames {
            let bestId = argmaxFrame(
                logprobs: logprobs,
                offset: 0 * stride0 + t * stride1,
                stride: stride2,
                count: vocabPlusBlank
            )
            if bestId == Self.blankId {
                prevId = -1            // Blanks terminate the dedupe run
                continue
            }
            if bestId == prevId { continue }
            emissions.append(CTCEmission(tokenId: bestId, frame: t))
            prevId = bestId
        }
        let tOut = realOutputFrames

        // Detokenise.
        var text = ""
        for em in emissions {
            guard let piece = vocab[em.tokenId] else { continue }
            if piece.hasPrefix("\u{2581}") {
                if !text.isEmpty { text += " " }
                text += String(piece.dropFirst())
            } else {
                text += piece
            }
        }
        text = collapseAdjacentDuplicates(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return FullResult(text: text, emissions: emissions, lastFrame: tOut - 1)
    }

    /// Collapse adjacent duplicate base letters (CTC over-emission cleanup
    /// that operates at the *letter* level — after SentencePiece pieces
    /// have already been concatenated). The model sometimes emits two
    /// SentencePiece tokens that share a boundary letter, producing
    /// outputs like `الَّذِيِينَ` (alladhi-ina) where the user said
    /// `الَّذِينَ` (alladhīna). Quranic Arabic uses **shadda** to
    /// indicate genuinely doubled consonants, so two unshaddaed adjacent
    /// copies of the same base letter are almost always a CTC artifact
    /// rather than legitimate text.
    private func collapseAdjacentDuplicates(_ text: String) -> String {
        var out: [Character] = []
        var lastBase: Character? = nil
        var shaddaSinceLastBase = false
        for ch in text {
            if Self.isArabicDiacritic(ch) {
                if ch == "\u{0651}" { shaddaSinceLastBase = true }
                out.append(ch)
                continue
            }
            if ch == " " {
                out.append(ch)
                lastBase = nil
                shaddaSinceLastBase = false
                continue
            }
            if ch == lastBase && !shaddaSinceLastBase {
                // Duplicate adjacent unshaddaed base letter — drop it.
                // We keep any diacritics that were already appended for
                // the kept copy; pending diacritics on this dropped copy
                // are also dropped (they belonged to the duplicate).
                continue
            }
            out.append(ch)
            lastBase = ch
            shaddaSinceLastBase = false
        }
        return String(out)
    }

    /// True for Arabic combining marks (tashkeel, Quranic annotation,
    /// superscript alef, tatweel) — i.e. anything that decorates a base
    /// letter without being one itself.
    private static func isArabicDiacritic(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if v >= 0x064B && v <= 0x065F { return true }   // tashkeel
            if v >= 0x0610 && v <= 0x061A { return true }   // Quranic annotation
            if v >= 0x06D6 && v <= 0x06ED { return true }   // Quranic recitation marks
            if v == 0x0640 || v == 0x0670 { return true }   // tatweel, superscript alef
        }
        return false
    }

    /// Argmax over the vocab axis for a single frame in an MLMultiArray.
    /// The re-exported model emits Float32 logprobs (compute_precision was
    /// set to FP32 to avoid the NaN bug the prior FP16 export had), so we
    /// read through a Float pointer.
    private func argmaxFrame(
        logprobs: MLMultiArray,
        offset: Int,
        stride: Int,
        count: Int
    ) -> Int {
        switch logprobs.dataType {
        case .float32:
            let ptr = logprobs.dataPointer.bindMemory(to: Float.self, capacity: count * stride)
            var bestIdx = 0
            var bestVal = ptr[offset]
            for i in 1..<count {
                let v = ptr[offset + i * stride]
                if v > bestVal {
                    bestVal = v
                    bestIdx = i
                }
            }
            return bestIdx
        case .float16:
            let ptr = logprobs.dataPointer.bindMemory(to: Float16.self, capacity: count * stride)
            var bestIdx = 0
            var bestVal: Float16 = ptr[offset]
            for i in 1..<count {
                let v = ptr[offset + i * stride]
                if v > bestVal {
                    bestVal = v
                    bestIdx = i
                }
            }
            return bestIdx
        default:
            // Fallback: use MLMultiArray's general accessor (slower, but
            // safe for any dtype CoreML might surface).
            var bestIdx = 0
            var bestVal = logprobs[offset].floatValue
            for i in 1..<count {
                let v = logprobs[offset + i * stride].floatValue
                if v > bestVal {
                    bestVal = v
                    bestIdx = i
                }
            }
            return bestIdx
        }
    }

    private func timestampedWord(_ text: String, startFrame: Int, endFrame: Int) -> TimestampedWord {
        // Subsampling: FastConformer encoder downsamples by a factor of 8
        // (configurable but 8 is the model default — 4× downsampling in the
        // subsampling conv then 2× by stride). Encoder-frame index × 8 ×
        // hop_length / sample_rate = seconds.
        let secondsPerEncoderFrame =
            Double(LogMelFeatures.hopLength * 8) / Double(LogMelFeatures.sampleRate)
        let start = Double(startFrame) * secondsPerEncoderFrame
        let end = Double(endFrame) * secondsPerEncoderFrame
        return TimestampedWord(text: text, start: start, end: end)
    }

    // MARK: - Bundle helpers

    private static func compiledModelURL() throws -> URL {
        // Xcode produces FastConformerQuran.mlmodelc in the app bundle.
        if let url = Bundle.main.url(forResource: "FastConformerQuran", withExtension: "mlmodelc") {
            return url
        }
        throw NSError(domain: "FastConformerQuranASR", code: 100,
                      userInfo: [NSLocalizedDescriptionKey: "FastConformerQuran.mlmodelc missing from bundle (check Xcode build settings)"])
    }

    /// `fastconformer-tokens.txt` is `<piece>\t<id>` per line, 1024 lines.
    /// The blank token (id 1024) is implicit and not in the file.
    private static func loadVocab() throws -> [Int: String] {
        guard let url = Bundle.main.url(forResource: "fastconformer-tokens", withExtension: "txt") else {
            throw NSError(domain: "FastConformerQuranASR", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "fastconformer-tokens.txt missing from bundle"])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var map: [Int: String] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            // Split on whitespace — handles both space- and tab-separated.
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let id = Int(parts[parts.count - 1]) else { continue }
            let piece = parts[0..<(parts.count - 1)].joined(separator: " ")
            map[id] = String(piece)
        }
        guard !map.isEmpty else {
            throw NSError(domain: "FastConformerQuranASR", code: 102,
                          userInfo: [NSLocalizedDescriptionKey: "vocab file is empty"])
        }
        return map
    }

    // MARK: - Audio loading

    /// Read a 16 kHz mono float32 PCM buffer.
    ///
    /// Our recordings come straight from `AVAudioRecorder` configured with
    /// 16 kHz mono 16-bit PCM (see `PronunciationChecker.beginRecording`),
    /// so AVAudioFile decodes them into a `processingFormat` that's
    /// always 16 kHz mono float32. We refuse anything else loudly — both
    /// for clarity and to avoid an `AVAudioConverter` callback path that
    /// Swift 6 strict-concurrency flags (non-Sendable buffer crossing a
    /// `@Sendable` closure).
    private func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == Double(LogMelFeatures.sampleRate),
              format.channelCount == 1
        else {
            throw NSError(domain: "FastConformerQuranASR", code: 200, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected audio format \(format.sampleRate) Hz × \(format.channelCount)ch (need 16 kHz mono)"
            ])
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }
}
