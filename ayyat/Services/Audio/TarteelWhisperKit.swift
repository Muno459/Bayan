import Foundation
import WhisperKit

/// Word with timestamp for forced alignment
struct TimestampedWord: Sendable {
    let text: String
    let start: Double
    let end: Double
}

/// Transcription result with word-level timestamps for forced alignment
struct TranscriptionWithTimestamps: Sendable {
    let text: String
    let words: [TimestampedWord]
    let duration: Double
}

/// Tarteel Whisper ASR using WhisperKit for Quranic Arabic transcription.
/// Uses the pre-converted whisper-base-ar-quran model optimized for Apple Neural Engine.
/// Loads CPU-only first for instant use, then upgrades to ANE in background.
final class TarteelWhisperKit: @unchecked Sendable {
    private var whisperKit: WhisperKit?
    private var isUsingANE = false

    /// Whether the model is loaded and ready for transcription
    var isLoaded: Bool { whisperKit != nil }

    /// Whether we're using the fast Neural Engine version
    var isOptimized: Bool { isUsingANE }

    /// Fast CPU-only initialization (~2s) - use this for instant loading
    init() async throws {
        try await loadCPUOnly()
    }

    /// Load CPU-only model for instant use
    private func loadCPUOnly() async throws {
        dlog("[TarteelWhisperKit] Loading CPU-only model (fast)...")
        let startTime = Date()

        guard let modelPath = Self.bundledModelFolderPath() else {
            dlog("[TarteelWhisperKit] ERROR: TarteelModels.bundle not found in app bundle!")
            throw TarteelWhisperKitError.transcriptionFailed("TarteelModels.bundle not found in bundle")
        }
        dlog("[TarteelWhisperKit] Model folder: \(modelPath)")

        let config = WhisperKitConfig(
            modelFolder: modelPath,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuOnly,
                textDecoderCompute: .cpuOnly,
                prefillCompute: .cpuOnly
            ),
            verbose: false,
            logLevel: .none,
            prewarm: false,  // Skip prewarm for CPU
            load: true,
            download: false
        )

        whisperKit = try await WhisperKit(config)
        let elapsed = Date().timeIntervalSince(startTime)
        dlog("[TarteelWhisperKit] CPU model loaded in \(String(format: "%.1f", elapsed))s")
    }

    /// Locates the TarteelModels.bundle folder shipped inside the app.
    /// Uses the `.bundle` suffix because xcodegen flattens plain folders
    /// into PBXGroups; a `.bundle` directory is preserved verbatim.
    static func bundledModelFolderPath() -> String? {
        Bundle.main.url(forResource: "TarteelModels", withExtension: "bundle")?.path
    }

    /// Upgrade to Neural Engine in background (for caching)
    /// Call this after CPU model is loaded - ANE version will be cached for future launches
    func upgradeToANE() async {
        guard !isUsingANE else { return }

        dlog("[TarteelWhisperKit] Upgrading to Neural Engine in background...")
        let startTime = Date()

        guard let modelPath = Self.bundledModelFolderPath() else {
            dlog("[TarteelWhisperKit] ERROR: TarteelModels.bundle not found for ANE upgrade")
            return
        }

        let config = WhisperKitConfig(
            modelFolder: modelPath,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndNeuralEngine,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine,
                prefillCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )

        do {
            let aneModel = try await WhisperKit(config)
            whisperKit = aneModel
            isUsingANE = true
            let elapsed = Date().timeIntervalSince(startTime)
            dlog("[TarteelWhisperKit] ANE model ready in \(String(format: "%.1f", elapsed))s (cached for next launch)")
        } catch {
            dlog("[TarteelWhisperKit] ANE upgrade failed: \(error) - continuing with CPU")
        }
    }

    /// Transcribe audio file to Arabic text.
    /// - Parameter url: URL of the audio file (WAV, M4A, etc.)
    /// - Returns: Transcribed Arabic text
    func transcribe(url: URL) async throws -> String {
        guard let whisperKit = whisperKit else {
            throw TarteelWhisperKitError.modelNotLoaded
        }

        // Transcribe with Arabic language hint
        // Use lower temperature for more deterministic output on short clips
        let options = DecodingOptions(
            task: .transcribe,
            language: "ar",
            temperature: 0.0,  // Greedy decoding - most accurate
            temperatureFallbackCount: 5,  // Retry with higher temps if needed
            sampleLength: 50,  // Short clips, expect few tokens
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let result = try await whisperKit.transcribe(
            audioPath: url.path,
            decodeOptions: options
        )

        // Return combined text from all segments
        let text = result.map { $0.text }.joined(separator: " ")
        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// Transcribe audio samples directly
    /// - Parameter samples: Float array of audio samples at 16kHz
    /// - Returns: Transcribed Arabic text
    func transcribe(samples: [Float]) async throws -> String {
        guard let whisperKit = whisperKit else {
            throw TarteelWhisperKitError.modelNotLoaded
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: "ar",
            temperature: 0.0,
            temperatureFallbackCount: 3,
            sampleLength: 50,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let result = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        let text = result.map { $0.text }.joined(separator: " ")
        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// Transcribe with word-level timestamps for forced alignment
    func transcribeWithTimestamps(url: URL) async throws -> TranscriptionWithTimestamps {
        guard let whisperKit = whisperKit else {
            throw TarteelWhisperKitError.modelNotLoaded
        }

        // Enable timestamps for forced alignment
        let options = DecodingOptions(
            task: .transcribe,
            language: "ar",
            temperature: 0.0,
            temperatureFallbackCount: 5,
            sampleLength: 100,
            skipSpecialTokens: true,
            withoutTimestamps: false,  // Get timestamps
            wordTimestamps: true       // Word-level timestamps
        )

        let results = try await whisperKit.transcribe(
            audioPath: url.path,
            decodeOptions: options
        )

        var allWords: [TimestampedWord] = []
        var totalDuration: Double = 0

        for result in results {
            // Access segments from result
            for segment in result.segments {
                // Get word-level timestamps if available
                if let words = segment.words {
                    for word in words {
                        let cleanWord = word.word.trimmingCharacters(in: CharacterSet.whitespaces)
                        if !cleanWord.isEmpty {
                            allWords.append(TimestampedWord(
                                text: cleanWord,
                                start: Double(word.start),
                                end: Double(word.end)
                            ))
                            totalDuration = max(totalDuration, Double(word.end))
                        }
                    }
                } else {
                    // Fallback: treat whole segment as one word
                    let cleanText = segment.text.trimmingCharacters(in: CharacterSet.whitespaces)
                    if !cleanText.isEmpty {
                        allWords.append(TimestampedWord(
                            text: cleanText,
                            start: Double(segment.start),
                            end: Double(segment.end)
                        ))
                        totalDuration = max(totalDuration, Double(segment.end))
                    }
                }
            }
        }

        let fullText = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        return TranscriptionWithTimestamps(
            text: fullText,
            words: allWords,
            duration: totalDuration
        )
    }
}

// MARK: - Errors

enum TarteelWhisperKitError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model not loaded"
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        }
    }
}
