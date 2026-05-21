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

    /// Quran Reflect (community Lessons / Reflections) lives under its own
    /// `/quran-reflect/v1` base — *not* under `/content/api/v4`. Requires the
    /// `post.read` scope, which is *not* on the default content credential;
    /// QF will return `insufficient_scope` until they approve our request.
    var quranReflectAPIBase: String {
        "\(apiBaseURL)/quran-reflect/v1"
    }

    // MARK: - Content API (client_credentials)
    //
    // Credentials issued for the ayyat app by Quran Foundation (2026-05-17).
    // The actual id/secret values live in `Secrets.swift` (git-ignored).
    //
    // - Pre-live: full feature set (Content + Search + User APIs) but limited
    //   sample content. Use this for development and the hackathon demo.
    // - Production: full Quran content; Search + User APIs unlocked via the
    //   "Request Additional Scopes" form.

    var clientId: String {
        switch self {
        case .prelive:    Secrets.shared.preliveClientId
        case .production: Secrets.shared.productionClientId
        }
    }

    var clientSecret: String {
        switch self {
        case .prelive:    Secrets.shared.preliveClientSecret
        case .production: Secrets.shared.productionClientSecret
        }
    }

    // MARK: - User API (authorization_code + PKCE, OIDC)
    //
    // For mobile apps, register a *public* OAuth client at
    // https://api-docs.quran.foundation/docs/tutorials/oidc/client-setup/
    // with redirect URI `com.mostafamahdi.ayyat://oauth-callback`.
    // If the content-API client_id above is already configured for both
    // grants, it can be reused. Otherwise paste the new client_id here.

    var oidcClientId: String {
        // QF currently issues a single confidential client for both
        // grants. If they ever issue a separate public OIDC client for the
        // iOS app, swap it in here.
        clientId
    }

    /// Confidential clients must authenticate at the token endpoint.
    /// Returns the same secret as the content-API for now — both grants
    /// share one client.
    var oidcClientSecret: String {
        clientSecret
    }

    /// Public redirect URI registered with Quran Foundation.
    /// iOS 17.4+ `ASWebAuthenticationSession.Callback.https(host:path:)`
    /// intercepts this URL directly using the `applinks:ayyat.net`
    /// associated-domains entitlement + AASA manifest — no Worker bridge
    /// or custom-scheme indirection needed.
    var oidcRedirectURI: String {
        "https://\(oidcCallbackHost)\(oidcCallbackPath)"
    }

    var oidcPostLogoutRedirectURI: String {
        "https://\(oidcCallbackHost)/oauth/logout"
    }

    var oidcCallbackHost: String { "ayyat.net" }
    var oidcCallbackPath: String { "/oauth/callback" }

    var oidcScopes: String {
        // Full scope set approved by Quran Foundation on the production
        // client (d090d6ab-f1e2-48a9-a67c-65206df2a32e). Ordered for
        // readability — server returns granted subset regardless of order.
        //
        //   openid           → required for OIDC sign-in
        //   offline_access   → returns a refresh_token
        //   user             → /userinfo expansion fields
        //   bookmark         → User API: bookmarks
        //   note             → User API: personal notes (My Reflections)
        //   reading_session  → User API: streak source-of-truth
        //   goal             → User API: daily goal target
        //   streak           → User API: streak read-back
        //   activity_day     → User API: per-day activity ledger
        //   preference       → User API: user settings
        //   collection       → User API: user-curated collections
        //   tag              → User API: tags on notes / posts
        //   post             → Quran Reflect: read community Lessons/Reflections
        //   comment          → Quran Reflect: comments on posts
        //   room             → Quran Reflect: discussion rooms
        //   search           → Search API
        "openid offline_access user bookmark note reading_session goal streak activity_day preference collection tag post comment room search"
    }
}

enum APIConfig {
    /// Single environment for everything that needs the authenticated host:
    ///   - OIDC sign-in (auth_code + PKCE)
    ///   - User API: bookmarks, notes, goals, reading sessions, streak
    ///   - Quran Reflect posts (Lessons / Reflections)
    ///
    /// Content reads bypass this entirely — `APIClient` calls the public
    /// `api.quran.com/api/v4` mirror, which serves the same v4 schema with
    /// no auth, full coverage (all 114 chapters, 126 translations, every
    /// tafsir, reciter audio, search, chapter info), and open CORS.
    static let current: APIEnvironment = .production
}
