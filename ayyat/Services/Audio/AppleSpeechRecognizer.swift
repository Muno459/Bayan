import Foundation
import Speech

/// Word with timestamp for forced alignment (shared with TarteelWhisperKit)
struct AppleTimestampedWord: Sendable {
    let text: String
    let start: Double
    let duration: Double
}

/// Apple Speech transcription result with timestamps
struct AppleTranscriptionResult: Sendable {
    let text: String
    let segments: [AppleTimestampedWord]
    let totalDuration: Double
}

/// Apple's built-in Speech Recognition for Arabic.
/// Instant loading, no model download needed.
final class AppleSpeechRecognizer: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?

    init() {
        // Arabic locale
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ar-SA"))
        dlog("[AppleSpeech] Initialized with Arabic locale, available: \(recognizer?.isAvailable ?? false)")
    }

    var isAvailable: Bool {
        recognizer?.isAvailable ?? false
    }

    /// Transcribe audio file to Arabic text (simple version)
    func transcribe(url: URL) async throws -> String {
        let result = try await transcribeWithTimestamps(url: url)
        return result.text
    }

    /// Transcribe with word-level timestamps for forced alignment
    func transcribeWithTimestamps(url: URL) async throws -> AppleTranscriptionResult {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw AppleSpeechError.notAvailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    dlog("[AppleSpeech] Error: \(error)")
                    continuation.resume(throwing: error)
                    return
                }

                guard let result = result, result.isFinal else { return }

                let transcription = result.bestTranscription
                let text = transcription.formattedString

                // Extract word-level timestamps from segments
                var segments: [AppleTimestampedWord] = []
                var totalDuration: Double = 0

                for segment in transcription.segments {
                    let word = segment.substring.trimmingCharacters(in: .whitespaces)
                    if !word.isEmpty {
                        segments.append(AppleTimestampedWord(
                            text: word,
                            start: segment.timestamp,
                            duration: segment.duration
                        ))
                        totalDuration = max(totalDuration, segment.timestamp + segment.duration)
                    }
                }

                dlog("[AppleSpeech] Result: '\(text)' (\(segments.count) segments, \(String(format: "%.2f", totalDuration))s)")
                for seg in segments {
                    dlog("[AppleSpeech]   - '\(seg.text)' [\(String(format: "%.2f", seg.start))-\(String(format: "%.2f", seg.start + seg.duration))s]")
                }

                continuation.resume(returning: AppleTranscriptionResult(
                    text: text,
                    segments: segments,
                    totalDuration: totalDuration
                ))
            }
        }
    }
}

enum AppleSpeechError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Speech recognition not available"
        }
    }
}
