import Foundation

enum APIEnvironment: String, Sendable {
    case prelive
    case production

    var authBaseURL: String {
        switch self {
        case .prelive: "https://prelive-oauth2.quran.foundation"
        case .production: "https://oauth2.quran.foundation"
        }
    }

    var apiBaseURL: String {
        switch self {
        case .prelive: "https://apis-prelive.quran.foundation"
        case .production: "https://apis.quran.foundation"
        }
    }

    var contentAPIBase: String {
        "\(apiBaseURL)/content/api/v4"
    }

    var userAPIBase: String {
        "\(apiBaseURL)/auth/v1"
    }

    var searchAPIBase: String {
        "\(apiBaseURL)/search/v1"
    }

    var clientId: String {
        switch self {
        case .prelive: "409e3a32-9106-44ad-82c6-a12d339a42ca"
        case .production: "a9c9b35d-be9a-4cab-9437-a26d40a130ce"
        }
    }

    var clientSecret: String {
        switch self {
        case .prelive: "0nh6KV5jvHMV972ZfMG9k1wr.p"
        case .production: "pLeLWSsVpc0vDRR0VPr6G_pOTN"
        }
    }
}

enum APIConfig {
    /// Switch to .production when ready for full Quran content
    static let current: APIEnvironment = .production
}
