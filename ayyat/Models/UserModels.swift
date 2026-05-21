import Foundation

struct Bookmark: Codable, Identifiable, Sendable {
    var id: String { verseKey }
    let verseKey: String
    let chapterId: Int
    let verseNumber: Int
    let createdAt: Date
    var note: String?

    /// Server-assigned bookmark id (Quran Foundation User API). Set
    /// after a successful POST /bookmarks. Required to call
    /// DELETE /bookmarks/{id} — the API does NOT support deleting by
    /// verse coordinates, only by this id. Nil for bookmarks added
    /// offline / before sync; those just stay until the next list
    /// fetch reconciles them.
    var remoteId: String?
}

struct ReadingSession: Codable, Identifiable, Sendable {
    let id: UUID
    let chapterId: Int
    let startVerseKey: String
    var endVerseKey: String?
    let startedAt: Date
    var endedAt: Date?
    var durationSeconds: Int

    var isActive: Bool { endedAt == nil }
}

struct ReadingStreak: Sendable {
    let currentDays: Int
    let longestDays: Int
    let lastReadDate: Date?
    let totalSessions: Int
    let totalMinutes: Int
}
