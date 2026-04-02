import Foundation

struct Chapter: Codable, Identifiable, Sendable {
    let id: Int
    let nameSimple: String
    let nameArabic: String
    let versesCount: Int
    let revelationPlace: String?
    let revelationOrder: Int?
    let pages: [Int]?

    enum CodingKeys: String, CodingKey {
        case id
        case nameSimple = "name_simple"
        case nameArabic = "name_arabic"
        case versesCount = "verses_count"
        case revelationPlace = "revelation_place"
        case revelationOrder = "revelation_order"
        case pages
    }
}

struct ChaptersResponse: Codable, Sendable {
    let chapters: [Chapter]
}
