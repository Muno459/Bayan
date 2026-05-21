import Foundation

/// One available tafsir resource (e.g. Ibn Kathir, Al-Jalalayn).
struct TafsirResource: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let authorName: String?
    let slug: String?
    let languageName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case authorName = "author_name"
        case slug
        case languageName = "language_name"
    }
}

struct TafsirsResponse: Codable, Sendable {
    let tafsirs: [TafsirResource]
}

/// Tafsir text for a single ayah.
struct TafsirText: Codable, Sendable {
    let resourceId: Int?
    let resourceName: String?
    let text: String
    let languageName: String?
    let verseKey: String?

    enum CodingKeys: String, CodingKey {
        case resourceId = "resource_id"
        case resourceName = "resource_name"
        case text
        case languageName = "language_name"
        case verseKey = "verse_key"
    }
}

struct TafsirByAyahResponse: Codable, Sendable {
    let tafsir: TafsirText
}

/// Wrapper for /verses/random and /verses/by_key responses.
struct SingleVerseResponse: Codable, Sendable {
    let verse: Verse
}
