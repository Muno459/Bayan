import Foundation
import SwiftUI

/// Manages user data: bookmarks, reading sessions, streaks.
/// Currently stores locally via UserDefaults. Ready to sync with
/// Quran Foundation User APIs once production scopes are approved.
@MainActor
@Observable
final class UserStore {
    // MARK: - Bookmarks

    private(set) var bookmarks: [Bookmark] = []

    func isBookmarked(_ verseKey: String) -> Bool {
        bookmarks.contains { $0.verseKey == verseKey }
    }

    func toggleBookmark(verseKey: String, chapterId: Int, verseNumber: Int) {
        if let index = bookmarks.firstIndex(where: { $0.verseKey == verseKey }) {
            bookmarks.remove(at: index)
        } else {
            let bookmark = Bookmark(
                verseKey: verseKey,
                chapterId: chapterId,
                verseNumber: verseNumber,
                createdAt: Date()
            )
            bookmarks.append(bookmark)
        }
        saveBookmarks()
    }

    // MARK: - Reading Sessions

    private(set) var sessions: [ReadingSession] = []
    private(set) var activeSession: ReadingSession?

    /// Last verse the user was reading — persisted for "Continue Reading"
    var lastReadChapterId: Int? {
        didSet { UserDefaults.standard.set(lastReadChapterId, forKey: "bayan_lastChapter") }
    }
    var lastReadVerseKey: String? {
        didSet { UserDefaults.standard.set(lastReadVerseKey, forKey: "bayan_lastVerse") }
    }

    func startSession(chapterId: Int, verseKey: String) {
        // End any existing session
        endCurrentSession()

        let session = ReadingSession(
            id: UUID(),
            chapterId: chapterId,
            startVerseKey: verseKey,
            endVerseKey: nil,
            startedAt: Date(),
            endedAt: nil,
            durationSeconds: 0
        )
        activeSession = session
    }

    func endCurrentSession() {
        guard var session = activeSession else { return }
        session.endedAt = Date()
        session.durationSeconds = Int(Date().timeIntervalSince(session.startedAt))
        sessions.append(session)
        activeSession = nil
        saveSessions()
        updateStreak()
    }

    // MARK: - Streaks

    private(set) var streak: ReadingStreak = ReadingStreak(
        currentDays: 0, longestDays: 0, lastReadDate: nil,
        totalSessions: 0, totalMinutes: 0
    )

    private func updateStreak() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Get unique reading days
        let readingDays = Set(sessions.compactMap { session -> Date? in
            guard let end = session.endedAt else { return nil }
            return calendar.startOfDay(for: end)
        }).sorted(by: >)

        // Calculate current streak
        var currentDays = 0
        var checkDate = today
        for day in readingDays {
            if calendar.isDate(day, inSameDayAs: checkDate) {
                currentDays += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
            } else if day < checkDate {
                break
            }
        }

        let totalMinutes = sessions.reduce(0) { $0 + $1.durationSeconds } / 60

        streak = ReadingStreak(
            currentDays: currentDays,
            longestDays: max(currentDays, streak.longestDays),
            lastReadDate: readingDays.first,
            totalSessions: sessions.count,
            totalMinutes: totalMinutes
        )
    }

    // MARK: - Persistence (UserDefaults for now, API sync later)

    private let bookmarksKey = "bayan_bookmarks"
    private let sessionsKey = "bayan_sessions"

    init() {
        loadBookmarks()
        loadSessions()
        updateStreak()
        lastReadChapterId = UserDefaults.standard.object(forKey: "bayan_lastChapter") as? Int
        lastReadVerseKey = UserDefaults.standard.string(forKey: "bayan_lastVerse")
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: bookmarksKey)
        }
    }

    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: bookmarksKey),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        }
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: sessionsKey)
        }
    }

    private func loadSessions() {
        if let data = UserDefaults.standard.data(forKey: sessionsKey),
           let saved = try? JSONDecoder().decode([ReadingSession].self, from: data) {
            sessions = saved
        }
    }

    // MARK: - Future: Quran Foundation User API Sync
    //
    // When production user scopes are approved, add:
    // - POST /bookmarks { key: verseKey, type: "ayah" }
    // - GET /bookmarks
    // - POST /reading-sessions { chapterId, startVerse, endVerse, duration }
    // - GET /streak
    //
    // These will use the same TokenManager with authorization_code + PKCE flow.
}
