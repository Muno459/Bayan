import Foundation

/// Manages OAuth2 token lifecycle for Content API (client_credentials flow)
@MainActor
@Observable
final class TokenManager {
    private var accessToken: String?
    private var tokenExpiresAt: Date?
    private var refreshTask: Task<String, Error>?

    private let environment: APIEnvironment

    init(environment: APIEnvironment = APIConfig.current) {
        self.environment = environment
    }

    /// Get a valid access token, refreshing if needed
    func getToken() async throws -> String {
        // Return cached token if still valid (with 60s buffer)
        if let token = accessToken,
           let expiresAt = tokenExpiresAt,
           expiresAt > Date().addingTimeInterval(60)
        {
            return token
        }

        // Prevent concurrent refresh requests (stampede prevention)
        if let existingTask = refreshTask {
            return try await existingTask.value
        }

        let task = Task<String, Error> {
            defer { refreshTask = nil }
            let token = try await requestToken()
            return token
        }
        refreshTask = task
        return try await task.value
    }

    /// Request a new token using client_credentials grant
    private func requestToken() async throws -> String {
        let url = URL(string: "\(environment.authBaseURL)/oauth2/token")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        // Basic auth: client_id:client_secret
        let credentials = "\(environment.clientId):\(environment.clientSecret)"
        let credentialsData = Data(credentials.utf8)
        let base64Credentials = credentialsData.base64EncodedString()
        request.setValue(
            "Basic \(base64Credentials)",
            forHTTPHeaderField: "Authorization"
        )

        request.httpBody = "grant_type=client_credentials&scope=content".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APIError.authFailed(statusCode: httpResponse.statusCode)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        self.accessToken = tokenResponse.accessToken
        self.tokenExpiresAt = Date().addingTimeInterval(
            TimeInterval(tokenResponse.expiresIn)
        )

        return tokenResponse.accessToken
    }

    /// Invalidate the current token (e.g., after a 401 response)
    func invalidateToken() {
        accessToken = nil
        tokenExpiresAt = nil
    }
}

private struct TokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}
