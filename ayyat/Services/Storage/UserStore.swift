import Foundation
import SwiftUI

/// Manages user data: bookmarks, reading sessions, streaks.
/// Stores locally via UserDefaults and (when signed in) syncs reading
/// sessions to the Quran Foundation User API.
@MainActor
@Observable
final class UserStore {
    /// Optional User API client. When set, completed reading sessions
    /// are POSTed to /auth/v1/reading_sessions. Sync is best-effort and
    /// never blocks the local save.
    var userAPI: UserAPIClient?

    // MARK: - Bookmarks

    private(set) var bookmarks: [Bookmark] = []

    func isBookmarked(_ verseKey: String) -> Bool {
        bookmarks.contains { $0.verseKey == verseKey }
    }

    func toggleBookmark(verseKey: String, chapterId: Int, verseNumber: Int) {
        let existing = bookmarks.first { $0.verseKey == verseKey }
        let isRemoving = existing != nil
        if isRemoving {
            bookmarks.removeAll { $0.verseKey == verseKey }
        } else {
            bookmarks.append(Bookmark(
                verseKey: verseKey,
                chapterId: chapterId,
                verseNumber: verseNumber,
                createdAt: Date(),
                remoteId: nil
            ))
        }
        saveBookmarks()

        // Best-effort sync to Quran Foundation User API. The API uses
        // server-assigned bookmark ids; for delete we need the id we
        // captured on the original add.
        if let api = userAPI {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isRemoving, let remoteId = existing?.remoteId {
                    _ = try? await api.deleteBookmark(id: remoteId)
                } else if !isRemoving {
                    let remote = try? await api.addBookmark(
                        chapterId: chapterId,
                        verseNumber: verseNumber
                    )
                    if let remote {
                        // Persist the server id so a later remove can
                        // call DELETE /bookmarks/{id}.
                        if let idx = self.bookmarks.firstIndex(where: { $0.verseKey == verseKey }) {
                            self.bookmarks[idx].remoteId = remote.id
                            self.saveBookmarks()
                        }
                    }
                }
            }
        }
    }

    /// Save a reflection on a verse (POST /auth/v1/notes). Returns the
    /// server-assigned note id on success — needed if the caller also
    /// wants to `publishReflection` it to QuranReflect.
    func saveReflection(verseKey: String, body: String) async -> String? {
        guard let api = userAPI else { return nil }
        return (try? await api.addNote(verseKey: verseKey, body: body)) ?? nil
    }

    /// POST /auth/v1/notes/{id}/publish — promote a saved reflection
    /// into a public QuranReflect post. Returns the new post id on
    /// success (nil if not signed in or the API fails).
    func publishReflection(noteId: String, body: String, verseKey: String) async -> Int? {
        guard let api = userAPI else { return nil }
        return (try? await api.publishNote(id: noteId, body: body, verseKey: verseKey)) ?? nil
    }

    /// PATCH /v1/notes/{id} — edit an existing reflection.
    @discardableResult
    func updateReflection(id: String, body: String) async -> Bool {
        guard let api = userAPI else { return false }
        return (try? await api.updateNote(id: id, body: body)) ?? false
    }

    /// DELETE /v1/notes/{id} — remove a reflection.
    @discardableResult
    func deleteReflection(id: String) async -> Bool {
        guard let api = userAPI else { return false }
        return (try? await api.deleteNote(id: id)) ?? false
    }

    /// GET /v1/notes/by-verse/{verseKey} — fetch the signed-in user's
    /// reflections on a specific verse for inline display in the reader.
    func reflectionsForVerse(_ verseKey: String) async -> [RemoteNote] {
        guard let api = userAPI else { return [] }
        return (try? await api.notesForVerse(verseKey: verseKey)) ?? []
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

    /// Finishes the current reading session. `lastVerseKey` (if provided)
    /// captures how far the reader scrolled — important for accurate
    /// progress-toward-goal calculations.
    func endCurrentSession(lastVerseKey: String? = nil) {
        guard var session = activeSession else { return }
        session.endedAt = Date()
        session.endVerseKey = lastVerseKey ?? session.startVerseKey
        session.durationSeconds = Int(Date().timeIntervalSince(session.startedAt))
        // Sessions of < 5 seconds are noise (e.g. accidental taps). Skip them.
        guard session.durationSeconds >= 5 else {
            activeSession = nil
            return
        }
        sessions.append(session)
        // Cap at ~1 year of daily sessions so the UserDefaults blob
        // doesn't grow unbounded — every save serialises the full array,
        // and UserDefaults has a practical 4 MB ceiling. Older entries
        // are still on the QF User API server (reading_sessions endpoint),
        // so we can re-hydrate from there if we ever need full history.
        if sessions.count > 365 {
            sessions.removeFirst(sessions.count - 365)
        }
        activeSession = nil
        saveSessions()
        updateStreak()

        // Sync to Quran Foundation in two parts (per their guide):
        //   • POST /reading-sessions ← latest position (for resume / recently-read)
        //   • POST /activity-days    ← seconds + ayah ranges (for streak / goal credit)
        if let api = userAPI {
            let snapshot = session
            let lastKey = snapshot.endVerseKey ?? snapshot.startVerseKey
            let parts = lastKey.split(separator: ":").compactMap { Int($0) }
            let chapterNumber = parts.first ?? snapshot.chapterId
            let verseNumber = parts.count >= 2 ? parts[1] : 1

            // Build inclusive range "start-end" for the activity-day credit.
            let rangeString = "\(snapshot.startVerseKey)-\(lastKey)"
            let seconds = max(1, snapshot.durationSeconds)

            dlog("[UserStore] syncing session to QF — \(rangeString), \(seconds)s")
            Task { @MainActor in
                do {
                    _ = try await api.postReadingSession(
                        chapterNumber: chapterNumber,
                        verseNumber: verseNumber
                    )
                    dlog("[UserStore] ✓ /reading-sessions accepted (\(chapterNumber):\(verseNumber))")
                } catch {
                    dlog("[UserStore] ✗ /reading-sessions failed: \(error)")
                }
                do {
                    _ = try await api.postActivityDayReading(
                        seconds: seconds,
                        ranges: [rangeString]
                    )
                    dlog("[UserStore] ✓ /activity-days accepted (\(rangeString), \(seconds)s)")
                    // Re-pull streak + today's plan so the UI reflects
                    // the credit we just posted.
                    await refreshServerProgress()
                } catch {
                    dlog("[UserStore] ✗ /activity-days failed: \(error)")
                }
            }
        }

        mirrorStateToWidgets()
    }

    /// Push the latest streak / goal / verses-today numbers into the App
    /// Group container so the home-screen widgets stay in sync. Cheap; called
    /// whenever any session-affecting state changes.
    func mirrorStateToWidgets() {
        AyyatSharedStorage.writeStreak(days: streak.currentDays, lastDate: streak.lastReadDate)

        let target = UserDefaults.standard.integer(forKey: "ayyat.dailyVerseGoal")
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let versesToday = sessions.reduce(0) { acc, s in
            guard let ended = s.endedAt, cal.isDate(ended, inSameDayAs: today) else { return acc }
            let start = Int(s.startVerseKey.split(separator: ":").last ?? "0") ?? 0
            let end = (s.endVerseKey.flatMap { Int($0.split(separator: ":").last ?? "0") }) ?? start
            return acc + max(1, end - start + 1)
        }
        AyyatSharedStorage.writeGoal(target: max(1, target), versesToday: versesToday)
    }

    // MARK: - Streaks

    private(set) var streak: ReadingStreak = ReadingStreak(
        currentDays: 0, longestDays: 0, lastReadDate: nil,
        totalSessions: 0, totalMinutes: 0
    )

    /// Latest streak day-count fetched from QF's
    /// `/v1/streaks/current-streak-days`. Falls back to the local
    /// `streak.currentDays` when offline / signed out.
    private(set) var remoteStreakDays: Int = 0

    /// Latest "today's goal plan" fetched from QF. Drives the
    /// progress ring shown on the Learn tab.
    private(set) var todaysGoalPlan: RemoteGoalPlan?

    /// Pull streak + today's plan from QF and store locally. Call from
    /// Learn-tab `.task` and after any `endCurrentSession`.
    func refreshServerProgress() async {
        guard let api = userAPI else { return }
        remoteStreakDays = await api.currentStreakDays()
        todaysGoalPlan = await api.todaysGoalPlan()
        mirrorStateToWidgets()
    }

    /// Best estimate of current streak — server value if signed in,
    /// otherwise the locally-computed one.
    var effectiveStreakDays: Int {
        remoteStreakDays > 0 ? remoteStreakDays : streak.currentDays
    }

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
