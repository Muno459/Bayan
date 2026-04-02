import Foundation

struct AudioFileResponse: Codable, Sendable {
    let audioFile: AudioFile

    enum CodingKeys: String, CodingKey {
        case audioFile = "audio_file"
    }
}

struct AudioFile: Codable, Sendable {
    let id: Int
    let chapterId: Int
    let fileSize: Int?
    let format: String?
    let audioUrl: String
    let timestamps: [VerseTimestamp]?

    enum CodingKeys: String, CodingKey {
        case id
        case chapterId = "chapter_id"
        case fileSize = "file_size"
        case format
        case audioUrl = "audio_url"
        case timestamps
    }
}

struct VerseTimestamp: Codable, Sendable {
    let verseKey: String
    let timestampFrom: Int
    let timestampTo: Int
    let segments: [[Int]]?

    enum CodingKeys: String, CodingKey {
        case verseKey = "verse_key"
        case timestampFrom = "timestamp_from"
        case timestampTo = "timestamp_to"
        case segments
    }

    /// Parse segments into structured WordTiming objects.
    /// API returns segments as arrays: [word_index, start_ms, end_ms]
    /// Some malformed segments may have fewer than 3 elements — skip those.
    var wordTimings: [WordTiming] {
        guard let segments else { return [] }
        return segments.compactMap { seg in
            guard seg.count >= 3 else { return nil }
            return WordTiming(
                wordIndex: seg[0],
                startMs: seg[1],
                endMs: seg[2]
            )
        }
    }
}

struct WordTiming: Sendable, Equatable {
    let wordIndex: Int
    let startMs: Int
    let endMs: Int
}
