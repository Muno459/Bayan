import Foundation

/// Chapter metadata: themes, revelation context, summary.
/// Returned from /content/api/v4/chapters/{id}/info.
struct ChapterInfo: Codable, Sendable {
    let id: Int?
    let chapterId: Int?
    let languageName: String?
    let shortText: String?
    let text: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case id
        case chapterId = "chapter_id"
        case languageName = "language_name"
        case shortText = "short_text"
        case text
        case source
    }
}

struct ChapterInfoResponse: Codable, Sendable {
    let chapterInfo: ChapterInfo

    enum CodingKeys: String, CodingKey {
        case chapterInfo = "chapter_info"
    }
}
