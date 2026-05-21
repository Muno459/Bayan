import Foundation

/// A "Quran Reflect" Lesson or Reflection — community-authored content
/// attached to one or more verses. Mirrors quran.com's Lessons / Reflections
/// tabs.
struct ReflectPost: Codable, Sendable, Identifiable {
    let id: Int
    let body: String?                 // HTML body
    let title: String?
    let type: String?                 // "lesson" | "reflection"
    let verses: [String]?             // ["2:255", "2:256"]
    let author: PostAuthor?
    let likes: Int?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, body, title, type, verses, author, likes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Tolerant decoder — QF's posts schema has shifted; accept either
    /// numeric or string ids, missing fields gracefully.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int.self, forKey: .id) {
            self.id = i
        } else if let s = try? c.decode(String.self, forKey: .id), let i = Int(s) {
            self.id = i
        } else {
            // Deterministic fallback so SwiftUI's ForEach diffing stays
            // stable across re-decodes. A random id would make each refresh
            // look like a brand-new list, causing card flicker.
            let body = (try? c.decode(String.self, forKey: .body)) ?? ""
            let createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
            self.id = abs((body + createdAt).hashValue)
        }
        self.body = try? c.decode(String.self, forKey: .body)
        self.title = try? c.decode(String.self, forKey: .title)
        self.type = try? c.decode(String.self, forKey: .type)
        self.verses = try? c.decode([String].self, forKey: .verses)
        self.author = try? c.decode(PostAuthor.self, forKey: .author)
        self.likes = try? c.decode(Int.self, forKey: .likes)
        self.createdAt = try? c.decode(String.self, forKey: .createdAt)
        self.updatedAt = try? c.decode(String.self, forKey: .updatedAt)
    }
}

struct PostAuthor: Codable, Sendable {
    let id: Int?
    let username: String?
    let firstName: String?
    let lastName: String?
    let avatar: String?

    enum CodingKeys: String, CodingKey {
        case id, username, avatar
        case firstName = "first_name"
        case lastName = "last_name"
    }

    /// Display name for cards.
    var displayName: String {
        if let f = firstName, let l = lastName, !f.isEmpty, !l.isEmpty {
            return "\(f) \(l)"
        }
        return firstName ?? username ?? "Anonymous"
    }
}

/// Tolerant of either {"posts":[…]} or {"data":[…]} shape.
struct PostsResponse: Codable, Sendable {
    let posts: [ReflectPost]?
    let data: [ReflectPost]?
}
