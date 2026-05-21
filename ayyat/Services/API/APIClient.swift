import Foundation

enum APIError: LocalizedError, Sendable {
    case invalidResponse
    case authFailed(statusCode: Int)
    case httpError(statusCode: Int, body: String?)
    case decodingError(String)
    case rateLimited
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server"
        case .authFailed(let code):
            "Authentication failed (HTTP \(code))"
        case .httpError(let code, let body):
            "HTTP \(code): \(body ?? "Unknown error")"
        case .decodingError(let detail):
            "Failed to decode response: \(detail)"
        case .rateLimited:
            "Rate limited. Please wait and try again"
        case .networkError(let detail):
            "Network error: \(detail)"
        }
    }
}

/// HTTP client for Quran Foundation APIs.
///
/// **Architecture (post 2026-05-18):** content reads no longer go through
/// the OAuth-protected `apis.quran.foundation` host. Quran Foundation also
/// publishes the same v4 schema at `api.quran.com/api/v4` with no auth and
/// open CORS — this is what the public quran.com website itself consumes,
/// and it has full coverage (114 chapters, all 126 translations, tafsirs,
/// reciter audio, search, chapter info, random verse). We use it for every
/// content read.
///
/// The authenticated host is reserved for endpoints that *genuinely* need a
/// user identity — Quran Reflect posts (`/quran-reflect/v1/posts/feed`) and
/// the User API (bookmarks, notes, goals, etc. — those live in
/// `UserAPIClient`, not here).
@MainActor
@Observable
final class APIClient {
    let tokenManager: TokenManager
    private let environment: APIEnvironment
    private let session: URLSession
    private let decoder: JSONDecoder

    /// Quran.com's public mirror of the v4 schema. No client_id, no bearer
    /// token, fully cached and CORS-enabled. Used for all *content* reads.
    static let publicContentBase = "https://api.quran.com/api/v4"

    init(environment: APIEnvironment = APIConfig.current) {
        // Default to the same env as User API / OIDC so the TokenManager
        // can mint tokens for the few endpoints that DO require auth
        // (posts/feed). The public content reads ignore `environment`
        // entirely.
        self.environment = environment
        self.tokenManager = TokenManager(environment: environment)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
    }

    // MARK: - Content API (public — api.quran.com/api/v4, no auth)

    func fetchChapters(language: String = "en") async throws -> [Chapter] {
        let response: ChaptersResponse = try await getPublic(
            "\(Self.publicContentBase)/chapters",
            queryItems: [URLQueryItem(name: "language", value: language)]
        )
        return response.chapters
    }

    func fetchVerses(
        chapterNumber: Int,
        page: Int = 1,
        perPage: Int = 50,
        translationId: Int = 131, // Saheeh International
        includeWords: Bool = true
    ) async throws -> VersesResponse {
        var queryItems = [
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "per_page", value: "\(perPage)"),
            URLQueryItem(name: "translations", value: "\(translationId)"),
            URLQueryItem(name: "fields", value: "text_uthmani,text_imlaei"),
        ]
        if includeWords {
            queryItems.append(URLQueryItem(name: "words", value: "true"))
            queryItems.append(
                URLQueryItem(
                    name: "word_fields",
                    value: "text_uthmani,text_imlaei,translation,transliteration"
                )
            )
        }

        return try await getPublic(
            "\(Self.publicContentBase)/verses/by_chapter/\(chapterNumber)",
            queryItems: queryItems
        )
    }

    func fetchReciters() async throws -> [Reciter] {
        // QF's `/resources/recitations` metadata table only exposes 12
        // of the ~28 reciter IDs actually accepted by
        // `/chapter_recitations/{id}/{chapter}`. `/resources/chapter_reciters`
        // (the full table) is 503'ing on api.quran.com right now too.
        // Rather than ship a half-populated picker, we hand-curate every
        // valid id ourselves — probed against the live endpoint and
        // mapped to the friendly reciter name.
        return Self.curatedReciters
    }

    /// Full set of reciters available via api.quran.com's
    /// `/chapter_recitations/{id}/{chapter}` endpoint. IDs verified
    /// against the live endpoint; names match the QF metadata where
    /// available, otherwise derived from the audio file path.
    private static let curatedReciters: [Reciter] = [
        .init(id:  13, name: "Saad al-Ghamdi",             style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:   7, name: "Mishari Rashid al-`Afasy",   style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id: 173, name: "Mishari Rashid al-`Afasy",   style: .init(name: "Murattal · streaming", languageName: "english"), translatedName: nil),
        .init(id:   1, name: "AbdulBaset AbdulSamad",      style: .init(name: "Mujawwad", languageName: "english"), translatedName: nil),
        .init(id:   2, name: "AbdulBaset AbdulSamad",      style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:   3, name: "Abdur-Rahman as-Sudais",     style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:   4, name: "Abu Bakr al-Shatri",         style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:   5, name: "Hani ar-Rifai",              style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:   6, name: "Mahmoud Khalil Al-Husary",   style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  12, name: "Mahmoud Khalil Al-Husary",   style: .init(name: "Muallim",  languageName: "english"), translatedName: nil),
        .init(id:   9, name: "Mohamed Siddiq al-Minshawi", style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:   8, name: "Mohamed Siddiq al-Minshawi", style: .init(name: "Mujawwad", languageName: "english"), translatedName: nil),
        .init(id: 168, name: "Mohamed Siddiq al-Minshawi", style: .init(name: "Kids repeat", languageName: "english"), translatedName: nil),
        .init(id:  10, name: "Sa`ud ash-Shuraym",          style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  11, name: "Abdul Muhsin al-Qasim",      style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  14, name: "Fares Abbad",                style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  15, name: "Nasser al-Thubaity",         style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  17, name: "Sahl Yaaseen",               style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  18, name: "Salah Bukhatir",             style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  19, name: "Ahmed ibn `Ali al-`Ajamy",   style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  20, name: "Sudais & Shuraim",           style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  21, name: "Abdul Aziz al-Ahmad",        style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  22, name: "Muhammad Ayyoob",            style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  23, name: "Tawfeeq as-Sawaaigh",        style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  24, name: "Abdullah Ali Jabir",         style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id:  26, name: "Maher al-Muaiqly",           style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id: 160, name: "Bandar Baleela",             style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id: 161, name: "Khalifah Al Tunaiji",        style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
        .init(id: 174, name: "Yasser Ad-Dussary",          style: .init(name: "Murattal", languageName: "english"), translatedName: nil),
    ]

    /// Fetch available Quran translations
    func fetchTranslations(language: String = "en") async throws -> [TranslationResource] {
        let response: TranslationsResponse = try await getPublic(
            "\(Self.publicContentBase)/resources/translations",
            queryItems: [URLQueryItem(name: "language", value: language)]
        )
        return response.translations
    }

    /// GET /chapters/{id}/info — themes, revelation context, summary.
    func fetchChapterInfo(chapterNumber: Int, language: String = "en") async throws -> ChapterInfo {
        let response: ChapterInfoResponse = try await getPublic(
            "\(Self.publicContentBase)/chapters/\(chapterNumber)/info",
            queryItems: [URLQueryItem(name: "language", value: language)]
        )
        return response.chapterInfo
    }

    // MARK: - Tafsir (Content API)

    /// List available tafsirs (Ibn Kathir, Al-Jalalayn, etc.).
    func fetchTafsirs(language: String = "en") async throws -> [TafsirResource] {
        let response: TafsirsResponse = try await getPublic(
            "\(Self.publicContentBase)/resources/tafsirs",
            queryItems: [URLQueryItem(name: "language", value: language)]
        )
        return response.tafsirs
    }

    /// Fetch a single tafsir's text for one ayah.
    /// Tafsir id 169 = Ibn Kathir abridged (English), good default.
    func fetchTafsir(tafsirId: Int, verseKey: String) async throws -> TafsirText {
        let response: TafsirByAyahResponse = try await getPublic(
            "\(Self.publicContentBase)/tafsirs/\(tafsirId)/by_ayah/\(verseKey)"
        )
        return response.tafsir
    }

    /// GET /quran-reflect/v1/posts/feed — community Lessons & Reflections.
    ///
    /// The QF Posts API is namespaced under `/quran-reflect/v1`, not under
    /// `/content/api/v4`, and uses bracket-filter query params instead of
    /// flat ones. Requires the `post.read` scope on the access token —
    /// our default credential doesn't have it yet, so calls 401 with
    /// `insufficient_scope` until QF approves the additional-scopes form.
    ///
    /// `type` values: `"lesson"` → postTypeIds=2, `"reflection"` → postTypeIds=1.
    func fetchPosts(verseKey: String, type: String? = nil, perPage: Int = 20) async throws -> [ReflectPost] {
        let parts = verseKey.split(separator: ":")
        guard parts.count == 2,
              let chapterId = Int(parts[0]),
              let verseNumber = Int(parts[1])
        else { return [] }

        var items = [
            URLQueryItem(name: "filter[references][0][chapterId]", value: "\(chapterId)"),
            URLQueryItem(name: "filter[references][0][from]", value: "\(verseNumber)"),
            URLQueryItem(name: "filter[references][0][to]", value: "\(verseNumber)"),
            URLQueryItem(name: "filter[languages]", value: "en"),
            URLQueryItem(name: "limit", value: "\(perPage)"),
            URLQueryItem(name: "page", value: "1"),
        ]
        if let type {
            // QF post type ids: 1 = reflection, 2 = lesson.
            let typeId = type.lowercased() == "lesson" ? "2" : "1"
            items.append(URLQueryItem(name: "filter[postTypeIds]", value: typeId))
        }
        let response: PostsResponse = try await get(
            "\(environment.quranReflectAPIBase)/posts/feed",
            queryItems: items
        )
        return response.posts ?? response.data ?? []
    }

    /// Random ayah — used for "Daily Ayah" / inspiration cards. Includes
    /// word-by-word data so the card can render through the substitution
    /// engine instead of showing raw Arabic.
    func fetchRandomVerse(translationId: Int = 131) async throws -> Verse {
        let response: SingleVerseResponse = try await getPublic(
            "\(Self.publicContentBase)/verses/random",
            queryItems: [
                URLQueryItem(name: "language", value: "en"),
                URLQueryItem(name: "translations", value: "\(translationId)"),
                URLQueryItem(name: "fields", value: "text_uthmani,text_imlaei,chapter_id"),
                URLQueryItem(name: "words", value: "true"),
                URLQueryItem(name: "word_fields", value: "text_uthmani,text_imlaei,translation,transliteration"),
            ]
        )
        return response.verse
    }

    // MARK: - Search

    /// Full-text Quran search. The public host exposes it at /api/v4/search
    /// rather than the OAuth host's /search/v1/search — different path,
    /// same response shape.
    func search(query: String, size: Int = 20, page: Int = 0) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let response: SearchResponse = try await getPublic(
            "\(Self.publicContentBase)/search",
            queryItems: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "size", value: "\(size)"),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "language", value: "en"),
            ]
        )
        return response.search.results
    }

    // MARK: - Audio

    func fetchAudioWithSegments(
        reciterId: Int,
        chapterNumber: Int
    ) async throws -> AudioFile {
        let response: AudioFileResponse = try await getPublic(
            "\(Self.publicContentBase)/chapter_recitations/\(reciterId)/\(chapterNumber)",
            queryItems: [URLQueryItem(name: "segments", value: "true")]
        )
        return response.audioFile
    }

    // MARK: - Generic GET (no auth) — public quran.com endpoints

    private func getPublic<T: Decodable>(
        _ urlString: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        guard var components = URLComponents(string: urlString) else {
            throw APIError.networkError("Invalid URL: \(urlString)")
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.networkError("Could not construct URL")
        }
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return try decodeResponse(data)
        case 429:
            throw APIError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8)
            throw APIError.httpError(statusCode: http.statusCode, body: body)
        }
    }

    // MARK: - Generic GET (auth) — Quran Reflect posts only

    private func get<T: Decodable>(
        _ urlString: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        guard var components = URLComponents(string: urlString) else {
            throw APIError.networkError("Invalid URL: \(urlString)")
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.networkError("Could not construct URL")
        }

        let token = try await tokenManager.getToken()

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "x-auth-token")
        request.setValue(environment.clientId, forHTTPHeaderField: "x-client-id")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401:
            // Token expired — refresh once and retry. Surface the real
            // retry status on failure rather than masking it as 401 so the
            // UI can distinguish "still unauthorized" from "5xx upstream".
            tokenManager.invalidateToken()
            let newToken = try await tokenManager.getToken()
            var retryRequest = request
            retryRequest.setValue(newToken, forHTTPHeaderField: "x-auth-token")
            let (retryData, retryResponse) = try await session.data(for: retryRequest)
            guard let retryHttp = retryResponse as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard (200...299).contains(retryHttp.statusCode) else {
                let body = String(data: retryData, encoding: .utf8)
                throw APIError.httpError(statusCode: retryHttp.statusCode, body: body)
            }
            return try decodeResponse(retryData)
        case 429:
            throw APIError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8)
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        return try decodeResponse(data)
    }

    private func decodeResponse<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error.localizedDescription)
        }
    }
}
