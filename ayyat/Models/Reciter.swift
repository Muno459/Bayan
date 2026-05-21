import Foundation

struct Reciter: Codable, Identifiable, Sendable, Hashable {
    let id: Int
    let name: String
    let style: ReciterStyle?
    let translatedName: TranslatedName?

    enum CodingKeys: String, CodingKey {
        case id, name, style
        case translatedName = "translated_name"
    }

    var displayName: String {
        if let styleName = style?.name {
            return "\(name) (\(styleName))"
        }
        return name
    }
}

struct ReciterStyle: Codable, Sendable, Hashable {
    let name: String
    let languageName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case languageName = "language_name"
    }
}

struct TranslatedName: Codable, Sendable, Hashable {
    let name: String
    let languageName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case languageName = "language_name"
    }
}

struct RecitersResponse: Codable, Sendable {
    let reciters: [Reciter]
}

// MARK: - Recitations endpoint (api.quran.com/api/v4/resources/recitations)
//
// The `/resources/chapter_reciters` endpoint we used to call is currently
// 503'ing on api.quran.com — leaves the picker blank. `/resources/recitations`
// is the working sibling and serves the same 12 reciters used by quran.com
// itself. The shape differs (flat string `style`, `reciter_name` instead
// of `name`), so we decode it separately and map to `Reciter`.
struct RecitationResource: Codable, Sendable {
    let id: Int
    let reciterName: String
    let style: String?
    let translatedName: TranslatedName?

    enum CodingKeys: String, CodingKey {
        case id, style
        case reciterName = "reciter_name"
        case translatedName = "translated_name"
    }

    var asReciter: Reciter {
        let s = style?.lowercased() == "none" ? nil : style
        return Reciter(
            id: id,
            name: reciterName,
            style: s.map { ReciterStyle(name: $0, languageName: nil) },
            translatedName: translatedName
        )
    }
}

struct RecitationsResponse: Codable, Sendable {
    let recitations: [RecitationResource]
}
