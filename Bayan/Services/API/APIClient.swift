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
            "Rate limited — please wait and try again"
        case .networkError(let detail):
            "Network error: \(detail)"
        }
    }
}

/// Authenticated HTTP client for Quran Foundation APIs
@MainActor
@Observable
final class APIClient {
    let tokenManager: TokenManager
    private let environment: APIEnvironment
    private let session: URLSession
    private let decoder: JSONDecoder

    init(environment: APIEnvironment = APIConfig.current) {
        self.environment = environment
        self.tokenManager = TokenManager(environment: environment)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
    }

    // MARK: - Content API

    func fetchChapters(language: String = "en") async throws -> [Chapter] {
        let response: ChaptersResponse = try await get(
            "\(environment.contentAPIBase)/chapters",
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

        return try await get(
            "\(environment.contentAPIBase)/verses/by_chapter/\(chapterNumber)",
            queryItems: queryItems
        )
    }

    func fetchAudioWithSegments(
        reciterId: Int = 7, // Mishari Al-Afasy
        chapterNumber: Int
    ) async throws -> AudioFile {
        let response: AudioFileResponse = try await get(
            "\(environment.contentAPIBase)/chapter_recitations/\(reciterId)/\(chapterNumber)",
            queryItems: [URLQueryItem(name: "segments", value: "true")]
        )
        return response.audioFile
    }

    // MARK: - Generic GET with auth

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
            // Token expired — refresh once and retry
            tokenManager.invalidateToken()
            let newToken = try await tokenManager.getToken()
            var retryRequest = request
            retryRequest.setValue(newToken, forHTTPHeaderField: "x-auth-token")
            let (retryData, retryResponse) = try await session.data(for: retryRequest)
            guard let retryHttp = retryResponse as? HTTPURLResponse,
                  (200...299).contains(retryHttp.statusCode)
            else {
                throw APIError.authFailed(statusCode: 401)
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
