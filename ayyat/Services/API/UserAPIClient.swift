import Foundation

/// HTTP client for the Quran Foundation **User API** (per-user data:
/// bookmarks, reading sessions, streaks). Requests are authenticated
/// with the user access token from `OIDCAuthService`, not the content
/// API's client_credentials token.
@MainActor
final class UserAPIClient {
    private let environment: APIEnvironment
    private let auth: OIDCAuthService
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(environment: APIEnvironment = APIConfig.current, auth: OIDCAuthService) {
        self.environment = environment
        self.auth = auth

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    // MARK: - Bookmarks
    //
    // Quran Foundation User API v1.0.0 bookmark schema (per the official
    // docs at api-docs.quran.foundation/docs/user_related_apis_versioned):
    //
    //   POST /bookmarks
    //     body:  { "type": "ayah", "key": <chapterId Int>, "verseNumber": <Int> }
    //     resp:  { "success": true, "data": { "id": "...", "createdAt": "...",
    //                                          "type": "ayah", "key": 1,
    //                                          "verseNumber": 5, "isReading": false,
    //                                          "isInDefaultCollection": true,
    //                                          "collectionsCount": 1, "group": "..." } }
    //
    //   GET /bookmarks  →  { "success": true, "data": [ {...same shape...} ],
    //                        "pagination": {...} }
    //
    //   DELETE /bookmarks/{id}    ← id is the SERVER id (string), NOT verseKey
    //
    // Previously we were POSTing `{key: "2:255", type: "ayah"}` (verseKey as
    // string) and deleting by verseKey, both wrong. The server returned 400.

    /// GET /auth/v1/bookmarks — list signed-in user's bookmarks.
    func listBookmarks() async throws -> [RemoteBookmark] {
        guard auth.isSignedIn else { return [] }
        let result: BookmarksListResponse = try await get("/bookmarks")
        return result.data ?? result.bookmarks ?? []
    }

    /// POST /auth/v1/bookmarks — save a verse bookmark for the signed-in user.
    /// Returns the server-assigned bookmark on success.
    /// Body matches QF OpenAPI `oneOf` variant 0: { key (chapter Int),
    /// type:"ayah", verseNumber, mushafId:4 }. `mushafId` is required to
    /// disambiguate against variant 1 (juz/page/surah bookmarks) — without
    /// it the API returns 422 "value does not match any of the allowed types".
    func addBookmark(chapterId: Int, verseNumber: Int) async throws -> RemoteBookmark? {
        guard auth.isSignedIn else { return nil }
        let body = BookmarkPayload(
            type: "ayah",
            key: chapterId,
            verseNumber: verseNumber,
            mushafId: 4
        )
        let data = try await rawRequest(method: "POST", path: "/bookmarks", body: body)
        if let wrapped = try? decoder.decode(BookmarkSingleResponse.self, from: data) {
            return wrapped.data
        }
        return try? decoder.decode(RemoteBookmark.self, from: data)
    }

    /// DELETE /auth/v1/bookmarks/{id} — remove a bookmark by its
    /// server-assigned id (NOT verseKey).
    @discardableResult
    func deleteBookmark(id: String) async throws -> Bool {
        guard auth.isSignedIn, !id.isEmpty else { return false }
        _ = try await send(method: "DELETE", path: "/bookmarks/\(id)")
        return true
    }

    // MARK: - Collections
    //
    // QF Collections API (OpenAPI verified):
    //   POST   /v1/collections                                body: { name }
    //   GET    /v1/collections                                response: { data: [Collection], pagination }
    //   POST   /v1/collections/{id}                           body: { name }   (rename)
    //   DELETE /v1/collections/{id}
    //   POST   /v1/collections/{id}/bookmarks                 body: { key (chapter), type:"ayah", verseNumber, mushafId:4 }
    //   DELETE /v1/collections/{id}/bookmarks/{bookmarkId}

    /// GET /v1/collections — list user's bookmark collections.
    /// Spec requires `first` or `last` for pagination. `first` is
    /// capped at 20 — passing 50 returns 422.
    func listCollections() async throws -> [RemoteCollection] {
        guard auth.isSignedIn else { return [] }
        let resp: CollectionsListResponse = try await getWithQuery(
            "/collections",
            query: [URLQueryItem(name: "first", value: "20")]
        )
        return resp.data ?? []
    }

    /// POST /v1/collections — create a new named collection.
    func createCollection(name: String) async throws -> RemoteCollection? {
        guard auth.isSignedIn, !name.isEmpty else { return nil }
        let data = try await rawRequest(
            method: "POST",
            path: "/collections",
            body: CollectionNamePayload(name: name)
        )
        let resp = try? decoder.decode(CollectionSingleResponse.self, from: data)
        return resp?.data
    }

    /// DELETE /v1/collections/{id} — remove a collection.
    @discardableResult
    func deleteCollection(id: String) async throws -> Bool {
        guard auth.isSignedIn, !id.isEmpty else { return false }
        _ = try await send(method: "DELETE", path: "/collections/\(id)")
        return true
    }

    /// POST /v1/collections/{id}/bookmarks — add a bookmark to a
    /// collection. Per spec the body is { key:chapter, type:"ayah",
    /// verseNumber, mushafId:4 }.
    @discardableResult
    func addBookmarkToCollection(
        collectionId: String,
        chapterId: Int,
        verseNumber: Int
    ) async throws -> Bool {
        guard auth.isSignedIn, !collectionId.isEmpty else { return false }
        _ = try await send(
            method: "POST",
            path: "/collections/\(collectionId)/bookmarks",
            body: CollectionBookmarkPayload(
                key: chapterId,
                type: "ayah",
                verseNumber: verseNumber,
                mushafId: 4
            )
        )
        return true
    }

    // MARK: - Notes (Reflections)
    //
    // QF Notes API per OpenAPI (api-docs.quran.foundation):
    //   server: https://apis.quran.foundation/auth
    //   paths:  /v1/notes (GET/POST), /v1/notes/{id} (DELETE)
    //
    // Our `userAPIBase` already = "<apiBase>/auth/v1", so the path
    // segment we pass here is just `/notes`. The prior 400s were from
    // body-shape mismatches:
    //   - missing `saveToQR` (required boolean)
    //   - `ranges` items were single verseKeys "2:255"; the API regex
    //     wants verse RANGES "2:255-2:255"

    /// POST /auth/v1/notes — save a personal reflection on a verse.
    /// Returns the server-assigned note id on success (nil on failure
    /// or when not signed in). Caller may then pass that id to
    /// `publishNote` to make it a public QuranReflect post.
    func addNote(verseKey: String, body: String) async throws -> String? {
        guard auth.isSignedIn else { return nil }
        let range = "\(verseKey)-\(verseKey)"
        let data = try await rawRequest(
            method: "POST",
            path: "/notes",
            body: NotePayload(body: body, saveToQR: false, ranges: [range])
        )
        // Server wraps the created note as {success, data: {...note...}}
        let resp = try? decoder.decode(NoteSingleResponse.self, from: data)
        return resp?.data?.id
    }

    /// GET /auth/v1/notes — list signed-in user's reflections.
    func listNotes() async throws -> [RemoteNote] {
        guard auth.isSignedIn else { return [] }
        let response: NotesListResponse = try await get("/notes")
        return response.data ?? response.notes ?? []
    }

    /// DELETE /auth/v1/notes/{id} — remove a saved reflection.
    @discardableResult
    func deleteNote(id: String) async throws -> Bool {
        guard auth.isSignedIn else { return false }
        _ = try await send(method: "DELETE", path: "/notes/\(id)")
        return true
    }

    /// PATCH /auth/v1/notes/{id} — update an existing reflection's body.
    @discardableResult
    func updateNote(id: String, body: String) async throws -> Bool {
        guard auth.isSignedIn, !id.isEmpty else { return false }
        _ = try await rawRequest(
            method: "PATCH",
            path: "/notes/\(id)",
            body: UpdateNotePayload(body: body)
        )
        return true
    }

    /// GET /auth/v1/notes/by-verse/{verseKey} — fetch any reflections
    /// the user has on a specific verse. Spec uses the verse key as
    /// both a path segment and a query parameter (`?verseKey=…`); send
    /// it as a query for safety since `1:5` contains a colon.
    func notesForVerse(verseKey: String) async throws -> [RemoteNote] {
        guard auth.isSignedIn else { return [] }
        let resp: NotesListResponse = try await getWithQuery(
            "/notes/by-verse/\(verseKey)",
            query: [URLQueryItem(name: "verseKey", value: verseKey)]
        )
        return resp.data ?? resp.notes ?? []
    }

    /// POST /auth/v1/notes/{id}/publish — publish a saved reflection
    /// to the QuranReflect community feed as a Post. Server returns the
    /// newly-created post id.
    func publishNote(id: String, body: String, verseKey: String) async throws -> Int? {
        guard auth.isSignedIn else { return nil }
        let range = "\(verseKey)-\(verseKey)"
        let data = try await rawRequest(
            method: "POST",
            path: "/notes/\(id)/publish",
            body: PublishNotePayload(body: body, ranges: [range])
        )
        let resp = try? decoder.decode(PublishNoteResponse.self, from: data)
        return resp?.data?.postId
    }

    // MARK: - Streaks (Activity API)

    /// GET /auth/v1/streaks/current-streak-days?type=QURAN — the user's
    /// current Quran-reading streak in days. The spec accepts only the
    /// enum value `QURAN` for this endpoint (not "reading" / "memorization"
    /// like some related endpoints — server returns 422 ValidationError
    /// otherwise). Returns 0 if not signed in or the API fails.
    func currentStreakDays() async -> Int {
        guard auth.isSignedIn else { return 0 }
        do {
            let resp: StreakDaysResponse = try await getWithQuery(
                "/streaks/current-streak-days",
                query: [URLQueryItem(name: "type", value: "QURAN")]
            )
            return resp.data?.days ?? 0
        } catch {
            dlog("[ayyat] currentStreakDays failed: \(error)")
            return 0
        }
    }

    // MARK: - Goals
    //
    // QF Goals API (OpenAPI verified):
    //   POST   /v1/goals
    //   GET    /v1/goals/estimate          (reading-time estimator)
    //   GET    /v1/goals/get-todays-plan   (today's required reading)
    //   PUT    /v1/goals/{id}              (update)
    //   DELETE /v1/goals/{id}              (delete)
    //
    // There is NO `GET /v1/goals` for listing — `listGoals()` was always
    // 404'ing. Removed. Use `todaysGoalPlan()` for the only data we
    // actually surface in the UI.

    /// POST /auth/v1/goals — create a daily-verses reading goal.
    @discardableResult
    func createDailyVersesGoal(target: Int) async throws -> Bool {
        guard auth.isSignedIn else { return false }
        _ = try await send(
            method: "POST",
            path: "/goals",
            body: GoalPayload(type: "daily_verses", target: target, active: true)
        )
        return true
    }

    /// GET /auth/v1/goals/get-todays-plan?type=QURAN_RANGE&mushafId=… —
    /// today's scheduled reading. The spec restricts `type` to
    /// `QURAN_TIME | QURAN_PAGES | QURAN_RANGE`. We use `QURAN_RANGE`
    /// since our reader credits Ayah ranges to Activity Days.
    /// Returns nil if no goal exists or the API fails.
    func todaysGoalPlan(mushafId: Int = 4) async -> RemoteGoalPlan? {
        guard auth.isSignedIn else { return nil }
        do {
            let resp: GoalPlanResponse = try await getWithQuery(
                "/goals/get-todays-plan",
                query: [
                    URLQueryItem(name: "type", value: "QURAN_RANGE"),
                    URLQueryItem(name: "mushafId", value: String(mushafId)),
                ]
            )
            return resp.data
        } catch {
            dlog("[ayyat] todaysGoalPlan failed: \(error)")
            return nil
        }
    }

    // MARK: - Reading sessions
    //
    // QF Reading-Sessions API (OpenAPI verified):
    //   POST /v1/reading-sessions       body: { chapterNumber: Int, verseNumber: Int }
    //
    // The path uses HYPHEN, not underscore. The body is just the last
    // visible chapter+verse — the server tracks the rest. The prior
    // shape with chapter_id/start_verse_key/duration/etc was completely
    // wrong and 400'd every time.

    @discardableResult
    func postReadingSession(chapterNumber: Int, verseNumber: Int) async throws -> Bool {
        guard auth.isSignedIn else { return false }
        _ = try await send(
            method: "POST",
            path: "/reading-sessions",
            body: ReadingSessionPayload(chapterNumber: chapterNumber, verseNumber: verseNumber)
        )
        return true
    }

    // MARK: - Activity Days (streak + goal credit)
    //
    // Per the QF API guide: "Reading Sessions answer where the user
    // resumes; Activity Days answer what should count toward streak /
    // goal progress." Both endpoints get hit when a reading session ends.
    //
    // POST /v1/activity-days
    //   required: type=QURAN
    //   optional: date (defaults to today), seconds, ranges (Ayah ranges),
    //             mushafId (default 4 = UthmaniHafs which matches our Quran data)

    @discardableResult
    func postActivityDayReading(seconds: Int, ranges: [String]) async throws -> Bool {
        guard auth.isSignedIn else { return false }
        _ = try await send(
            method: "POST",
            path: "/activity-days",
            body: ActivityDayPayload(
                type: "QURAN",
                seconds: seconds,
                ranges: ranges,
                mushafId: 4
            )
        )
        return true
    }
}

private struct ActivityDayPayload: Encodable {
    let type: String       // "QURAN"
    let seconds: Int
    let ranges: [String]   // e.g. ["1:5-1:7"]
    let mushafId: Int      // 4 = UthmaniHafs
}

private struct ReadingSessionPayload: Encodable {
    let chapterNumber: Int
    let verseNumber: Int
}

// Legacy ReadingSession payload removed — actual /v1/reading-sessions
// schema is just { chapterNumber, verseNumber }. See `ReadingSessionPayload`
// above for the live shape.
private struct _LegacyReadingSessionPayload_REMOVED {
    let chapterId: Int
    let startVerseKey: String
    let endVerseKey: String?
    let durationSeconds: Int
    let startedAt: Date
    let endedAt: Date

    enum CodingKeys: String, CodingKey {
        case chapterId = "chapter_id"
        case startVerseKey = "start_verse_key"
        case endVerseKey = "end_verse_key"
        case durationSeconds = "duration_seconds"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

// MARK: - Internal request helpers

private extension UserAPIClient {
    func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(method: "GET", path: path, body: Optional<Empty>.none)
    }

    /// GET with query parameters appended to `userAPIBase + path`.
    func getWithQuery<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        guard var comp = URLComponents(string: "\(environment.userAPIBase)\(path)") else {
            throw APIError.networkError("bad URL \(path)")
        }
        comp.queryItems = (comp.queryItems ?? []) + query
        guard let finalURL = comp.url else { throw APIError.networkError("bad URL \(path)") }
        // Hand-build the request because rawRequest takes a path, not a URL.
        let token = try await auth.getValidAccessToken()
        var req = URLRequest(url: finalURL)
        req.httpMethod = "GET"
        req.setValue(token, forHTTPHeaderField: "x-auth-token")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(environment.clientId, forHTTPHeaderField: "x-client-id")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let s = String(data: data, encoding: .utf8) ?? "<no body>"
            dlog("[ayyat] GET \(path) failed \(http.statusCode): \(s)")
            throw APIError.httpError(statusCode: http.statusCode, body: s)
        }
        return try decoder.decode(T.self, from: data)
    }

    func send<B: Encodable>(method: String, path: String, body: B? = nil) async throws -> Data {
        try await rawRequest(method: method, path: path, body: body)
    }

    func send(method: String, path: String) async throws -> Data {
        try await rawRequest(method: method, path: path, body: Optional<Empty>.none)
    }

    func request<T: Decodable, B: Encodable>(method: String, path: String, body: B?) async throws -> T {
        let data = try await rawRequest(method: method, path: path, body: body)
        if data.isEmpty {
            throw APIError.invalidResponse
        }
        return try decoder.decode(T.self, from: data)
    }

    func rawRequest<B: Encodable>(method: String, path: String, body: B?) async throws -> Data {
        let token = try await auth.getValidAccessToken()
        guard let url = URL(string: "\(environment.userAPIBase)\(path)") else {
            throw APIError.networkError("bad URL \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // QF User API auth: per the OpenAPI security scheme, the JWT
        // goes in the `x-auth-token` header — NOT in the standard
        // `Authorization: Bearer ...`. We were sending it as Bearer for
        // months, which is why every reflection / bookmark / reading-
        // session request 400'd with "missing required headers or is
        // invalid". Sending BOTH headers below so future changes to the
        // spec don't break us either way.
        req.setValue(token, forHTTPHeaderField: "x-auth-token")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(environment.clientId, forHTTPHeaderField: "x-client-id")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(body)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let s = String(data: data, encoding: .utf8) ?? "<no body>"
            dlog("[ayyat] \(method) \(path) failed \(http.statusCode): \(s)")
            throw APIError.httpError(statusCode: http.statusCode, body: s)
        }
        return data
    }
}

private struct Empty: Encodable {}

private struct BookmarkPayload: Encodable {
    let type: String        // "ayah"
    let key: Int            // chapter id (NOT a verseKey string)
    let verseNumber: Int    // verse number within the chapter
    let mushafId: Int       // 4 = UthmaniHafs (matches our local Quran data)
}

private struct NotePayload: Encodable {
    let body: String           // 6-10000 chars
    let saveToQR: Bool         // required by the API — whether to publish to QuranReflect
    let ranges: [String]       // verse-range strings "X:Y-X:Y"
}

/// Remote bookmark shape from Quran Foundation User API v1.0.0.
///
/// Server schema (verbatim from docs):
///   { "id": "...", "createdAt": "...", "type": "ayah", "key": 1,
///     "verseNumber": 5, "group": "...", "isInDefaultCollection": true,
///     "isReading": false, "collectionsCount": 1 }
///
/// `key` is the chapter id (Int), `verseNumber` is the verse within that
/// chapter. Reconstruct a "1:5" style verse key with `verseKey`.
struct RemoteBookmark: Codable, Sendable {
    let id: String
    let type: String?
    let key: Int?
    let verseNumber: Int?
    let createdAt: String?
    let isReading: Bool?
    let isInDefaultCollection: Bool?

    enum CodingKeys: String, CodingKey {
        case id, type, key, verseNumber, createdAt, isReading, isInDefaultCollection
    }

    /// `"<key>:<verseNumber>"` style identifier, or nil if either component
    /// is missing.
    var verseKey: String? {
        guard let key, let verseNumber else { return nil }
        return "\(key):\(verseNumber)"
    }

    /// Tolerate either string or int `id`s for forward-compat (schema
    /// has shifted between snake_case and camelCase before).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            self.id = s
        } else if let i = try? c.decode(Int.self, forKey: .id) {
            self.id = String(i)
        } else {
            self.id = UUID().uuidString
        }
        self.type = try? c.decode(String.self, forKey: .type)
        self.key = try? c.decode(Int.self, forKey: .key)
        self.verseNumber = try? c.decode(Int.self, forKey: .verseNumber)
        self.createdAt = try? c.decode(String.self, forKey: .createdAt)
        self.isReading = try? c.decode(Bool.self, forKey: .isReading)
        self.isInDefaultCollection = try? c.decode(Bool.self, forKey: .isInDefaultCollection)
    }
}

private struct BookmarksListResponse: Decodable {
    // QF API has shifted shapes; accept either {"data":[…]} or {"bookmarks":[…]}.
    let data: [RemoteBookmark]?
    let bookmarks: [RemoteBookmark]?
}

private struct BookmarkSingleResponse: Decodable {
    let data: RemoteBookmark?
}

/// Remote note (Reflection) shape from /auth/v1/notes.
struct RemoteNote: Codable, Sendable, Identifiable {
    let id: String
    let body: String
    let ranges: [String]?
    let createdAt: String?
    let updatedAt: String?

    /// Convenience: first verse-key in the note's range list.
    var verseKey: String? { ranges?.first }

    enum CodingKeys: String, CodingKey {
        case id
        case body
        case ranges
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // The QF API has historically used either string or int IDs;
    // tolerate both.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            self.id = s
        } else if let i = try? c.decode(Int.self, forKey: .id) {
            self.id = String(i)
        } else {
            self.id = UUID().uuidString
        }
        self.body = (try? c.decode(String.self, forKey: .body)) ?? ""
        self.ranges = try? c.decode([String].self, forKey: .ranges)
        self.createdAt = try? c.decode(String.self, forKey: .createdAt)
        self.updatedAt = try? c.decode(String.self, forKey: .updatedAt)
    }
}

private struct NoteSingleResponse: Decodable {
    let success: Bool?
    let data: RemoteNote?
}

private struct UpdateNotePayload: Encodable {
    let body: String        // 6-10000 chars
}

// MARK: - Collections

private struct CollectionNamePayload: Encodable {
    let name: String
}

private struct CollectionBookmarkPayload: Encodable {
    let key: Int          // chapter id
    let type: String      // "ayah"
    let verseNumber: Int
    let mushafId: Int     // 4 = UthmaniHafs
}

struct RemoteCollection: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let slug: String?
    let isPrivate: Bool?
    let isDefault: Bool?
    let bookmarksCount: Int?
    let resourcesCount: Int?
    let updatedAt: String?
}

private struct CollectionsListResponse: Decodable {
    let success: Bool?
    let data: [RemoteCollection]?
}

private struct CollectionSingleResponse: Decodable {
    let success: Bool?
    let data: RemoteCollection?
}

private struct NotesListResponse: Decodable {
    let data: [RemoteNote]?
    let notes: [RemoteNote]?
}

private struct GoalPayload: Encodable {
    let type: String
    let target: Int
    let active: Bool
}

/// Lightweight goal shape (the QF spec keeps evolving; tolerate optional fields).
struct RemoteGoal: Codable, Sendable, Identifiable {
    let id: String
    let type: String?
    let target: Int?
    let active: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            self.id = s
        } else if let i = try? c.decode(Int.self, forKey: .id) {
            self.id = String(i)
        } else {
            self.id = UUID().uuidString
        }
        self.type = try? c.decode(String.self, forKey: .type)
        self.target = try? c.decode(Int.self, forKey: .target)
        self.active = try? c.decode(Bool.self, forKey: .active)
    }

    enum CodingKeys: String, CodingKey {
        case id, type, target, active
    }
}

// MARK: - Publish-note / Streak shapes

private struct PublishNotePayload: Encodable {
    let body: String
    let ranges: [String]
}

private struct PublishNoteResponse: Decodable {
    struct Data: Decodable {
        let success: Bool?
        let postId: Int?
    }
    let success: Bool?
    let data: Data?
}

private struct StreakDaysResponse: Decodable {
    struct Data: Decodable { let days: Int }
    let success: Bool?
    let data: Data?
}

/// Subset of the QF "today's goal plan" response. Strict-Decodable but
/// only carries the fields the UI consumes (id, date, progress 0–1,
/// ranges, secondsRead, versesRead).
struct RemoteGoalPlan: Decodable, Sendable {
    let id: String?
    let date: String?
    let progress: Double?
    let ranges: [String]?
    let pagesRead: Double?
    let secondsRead: Int?
    let versesRead: Int?
}

private struct GoalPlanResponse: Decodable {
    let success: Bool?
    let data: RemoteGoalPlan?
}

private struct GoalsListResponse: Decodable {
    let data: [RemoteGoal]?
    let goals: [RemoteGoal]?
}
