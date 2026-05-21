import Foundation

/// One hit from the Quran search API.
struct SearchResult: Codable, Sendable, Identifiable {
    let verseId: Int?
    let verseKey: String
    let text: String?
    let translations: [SearchTranslation]?
    let highlighted: String?

    var id: String { verseKey }

    enum CodingKeys: String, CodingKey {
        case verseId = "verse_id"
        case verseKey = "verse_key"
        case text
        case translations
        case highlighted
    }
}

struct SearchTranslation: Codable, Sendable {
    let text: String
    let resourceId: Int?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case text
        case resourceId = "resource_id"
        case name
    }
}

struct SearchResponse: Codable, Sendable {
    let search: SearchPayload
}

struct SearchPayload: Codable, Sendable {
    let query: String?
    let totalResults: Int?
    let currentPage: Int?
    let totalPages: Int?
    let results: [SearchResult]

    enum CodingKeys: String, CodingKey {
        case query
        case totalResults = "total_results"
        case currentPage = "current_page"
        case totalPages = "total_pages"
        case results
    }
}
