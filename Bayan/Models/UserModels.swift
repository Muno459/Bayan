import Foundation

struct Bookmark: Codable, Identifiable, Sendable {
    var id: String { verseKey }
    let verseKey: String
    let chapterId: Int
    let verseNumber: Int
    let createdAt: Date
    var note: String?
}

struct ReadingSession: Codable, Identifiable, Sendable {
    let id: UUID
    let chapterId: Int
    let startVerseKey: String
    let endVerseKey: String?
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
