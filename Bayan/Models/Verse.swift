import Foundation

struct Verse: Codable, Identifiable, Sendable {
    let id: Int
    let verseKey: String
    let verseNumber: Int
    let textUthmani: String?
    let textImlaei: String?
    let words: [Word]?
    let translations: [Translation]?

    enum CodingKeys: String, CodingKey {
        case id
        case verseKey = "verse_key"
        case verseNumber = "verse_number"
        case textUthmani = "text_uthmani"
        case textImlaei = "text_imlaei"
        case words
        case translations
    }
}

struct Word: Codable, Identifiable, Sendable {
    let id: Int
    let position: Int
    let textUthmani: String?
    let textImlaei: String?
    let translation: WordTranslation?
    let transliteration: WordTransliteration?
    let charTypeName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case position
        case textUthmani = "text_uthmani"
        case textImlaei = "text_imlaei"
        case translation
        case transliteration
        case charTypeName = "char_type_name"
    }

    /// Whether this is an actual word (not a verse number marker)
    var isWord: Bool {
        charTypeName == "word"
    }
}

struct WordTranslation: Codable, Sendable {
    let text: String?
    let languageName: String?

    enum CodingKeys: String, CodingKey {
        case text
        case languageName = "language_name"
    }
}

struct WordTransliteration: Codable, Sendable {
    let text: String?
    let languageName: String?

    enum CodingKeys: String, CodingKey {
        case text
        case languageName = "language_name"
    }
}

struct Translation: Codable, Identifiable, Sendable {
    let id: Int
    let resourceId: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case resourceId = "resource_id"
        case text
    }
}

struct VersesResponse: Codable, Sendable {
    let verses: [Verse]
    let pagination: Pagination?
}

struct Pagination: Codable, Sendable {
    let perPage: Int
    let currentPage: Int
    let totalPages: Int
    let totalRecords: Int

    enum CodingKeys: String, CodingKey {
        case perPage = "per_page"
        case currentPage = "current_page"
        case totalPages = "total_pages"
        case totalRecords = "total_records"
    }
}
