import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

/// OIDC authorization-code + PKCE flow for the Quran Foundation User API.
///
/// Flow:
/// 1. `signIn()` generates a PKCE verifier+challenge and launches
///    `ASWebAuthenticationSession` against the Quran Foundation /oauth2/auth endpoint.
/// 2. User authenticates on Quran Foundation web; provider redirects to
///    `com.mostafamahdi.ayyat://oauth-callback?code=...&state=...`.
/// 3. The callback URL is parsed; `code` is exchanged at /oauth2/token using
///    the PKCE verifier (no client secret — iOS is a public client).
/// 4. Tokens are persisted to Keychain. `accessToken` is exposed for the
///    User API client to attach as `Authorization: Bearer ...`.
@MainActor
@Observable
final class OIDCAuthService: NSObject {
    private let environment: APIEnvironment

    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private(set) var idToken: String?
    private(set) var expiresAt: Date?

    /// Profile info fetched from /userinfo after token exchange. Drives the
    /// "signed in as ..." label in Settings.
    private(set) var userInfo: OIDCUserInfo?

    /// True while a sign-in flow is mid-flight. Lets the UI show a spinner.
    private(set) var isSigningIn = false

    var isSignedIn: Bool { accessToken != nil }

    private var pkceVerifier: String?
    private var oauthState: String?

    init(environment: APIEnvironment = APIConfig.current) {
        self.environment = environment
        super.init()
        loadFromKeychain()
    }

    // MARK: - Public

    /// Launch the OIDC sign-in flow. Returns once tokens are persisted.
    func signIn() async throws {
        // Defensive reset: a previous attempt that was dismissed in a way
        // ASWebAuthenticationSession can't surface (swipe-down, etc.) could
        // leave isSigningIn or the PKCE state stuck. Wipe the slate before
        // starting a new attempt so the button is never permanently locked.
        isSigningIn = true
        isHandlingExternalCallback = false
        defer { isSigningIn = false }

        let verifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomString(length: 32)
        self.pkceVerifier = verifier
        self.oauthState = state

        var components = URLComponents(string: "\(environment.authBaseURL)/oauth2/auth")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: environment.oidcClientId),
            URLQueryItem(name: "redirect_uri", value: environment.oidcRedirectURI),
            URLQueryItem(name: "scope", value: environment.oidcScopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Light hint to QF so the consent page can pre-populate locale.
            URLQueryItem(name: "ui_locales", value: Locale.current.identifier),
        ]
        guard let authURL = components.url else { throw OIDCError.invalidAuthURL }
        dlog("[OIDC] starting session url=\(authURL.absoluteString)")
        dlog("[OIDC] expected callback=https://\(environment.oidcCallbackHost)\(environment.oidcCallbackPath)")
        dlog("[OIDC] expected redirect_uri=\(environment.oidcRedirectURI)")

        let callbackURL = try await startWebAuthSession(authURL: authURL)
        dlog("[OIDC] received callback=\(callbackURL.absoluteString)")
        try await handleCallback(callbackURL)
        dlog("[OIDC] sign-in complete, token exp=\(expiresAt?.description ?? "n/a")")
        // Hydrate the profile in the background — UI shows it when ready.
        Task { await refreshUserInfo() }
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        idToken = nil
        expiresAt = nil
        userInfo = nil
        // Clear any in-flight sign-in scaffolding too, otherwise a sign-in
        // that was abandoned mid-flow (or in-flight when the user tapped
        // Sign Out) could leave isSigningIn stuck true — disabling the
        // Sign In button until the app is relaunched.
        isSigningIn = false
        isHandlingExternalCallback = false
        pkceVerifier = nil
        oauthState = nil
        KeychainHelper.delete(Keys.accessToken)
        KeychainHelper.delete(Keys.refreshToken)
        KeychainHelper.delete(Keys.idToken)
        KeychainHelper.delete(Keys.expiresAt)
        KeychainHelper.delete(Keys.userInfo)
    }

    /// GET /userinfo with the current access token, fan-out into `userInfo`.
    func refreshUserInfo() async {
        guard let token = try? await getValidAccessToken() else { return }
        var request = URLRequest(url: URL(string: "\(environment.authBaseURL)/userinfo")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return }
        if let info = try? JSONDecoder().decode(OIDCUserInfo.self, from: data) {
            self.userInfo = info
            if let raw = String(data: data, encoding: .utf8) {
                KeychainHelper.save(raw, forKey: Keys.userInfo)
            }
        }
    }

    /// Whether we're already mid-handling an external callback. Two near-
    /// simultaneous URL openings would both pass the `pkceVerifier != nil`
    /// guard before either had a chance to clear it, leaving them racing
    /// to exchange the same auth code.
    private var isHandlingExternalCallback = false

    /// Safety net for the universal-link path. With iOS 17.4+'s
    /// `Callback.https` the session normally catches the callback inside
    /// ASWebAuthenticationSession before it can leak out. This stays as
    /// belt-and-braces in case a callback ever fires the universal link
    /// outside an active session (e.g. user opened a stale link from Mail).
    func handleExternalCallback(_ url: URL) async {
        guard url.path == environment.oidcCallbackPath else { return }
        guard pkceVerifier != nil else { return }
        guard !isHandlingExternalCallback else { return }
        isHandlingExternalCallback = true
        defer { isHandlingExternalCallback = false }
        do {
            try await handleCallback(url)
        } catch {
            dlog("[ayyat] handleExternalCallback failed: \(error)")
        }
    }

    /// Get a valid access token, refreshing if needed.
    ///
    /// If the refresh token is dead (revoked / expired / corrupted), we
    /// clear it from memory + Keychain so the UI flips cleanly to
    /// "signed out" instead of looping refresh attempts on every launch.
    func getValidAccessToken() async throws -> String {
        if let token = accessToken,
           let expiresAt,
           expiresAt > Date().addingTimeInterval(60)
        {
            return token
        }

        if let refreshToken {
            do {
                try await refresh(refreshToken: refreshToken)
                if let token = accessToken { return token }
            } catch {
                dlog("[OIDC] refresh failed, signing out: \(error)")
                signOut()
                throw OIDCError.notSignedIn
            }
        }

        throw OIDCError.notSignedIn
    }

    // MARK: - Web auth session

    private func startWebAuthSession(authURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // iOS 17.4+ native HTTPS callback. ASWebAuthenticationSession
            // intercepts the redirect to https://ayyat.net/oauth/callback
            // directly via the existing `applinks:ayyat.net` entitlement +
            // AASA manifest — no Worker bridge, no custom-scheme tricks.
            let callback = ASWebAuthenticationSession.Callback.https(
                host: environment.oidcCallbackHost,
                path: environment.oidcCallbackPath
            )
            // Defense in depth: catch any rare double-fire from the session
            // completion handler.
            let claim = ResumeOnce()
            let session = ASWebAuthenticationSession(
                url: authURL,
                callback: callback
            ) { callbackURL, error in
                guard claim.tryClaim() else {
                    dlog("[OIDC] session fired again — ignored (already resumed)")
                    return
                }
                if let error {
                    dlog("[OIDC] session error: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    dlog("[OIDC] session completed but URL was nil")
                    continuation.resume(throwing: OIDCError.noCallbackURL)
                    return
                }
                dlog("[OIDC] session caught \(callbackURL.absoluteString)")
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // Ephemeral session: no Safari cookie pollution, no OS-level
            // "Sign In Required" prompt. Cleaner first-run UX.
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func tryClaim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - Token exchange + refresh

    private func handleCallback(_ url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OIDCError.invalidCallback
        }
        let items = components.queryItems ?? []

        if let errorParam = items.first(where: { $0.name == "error" })?.value {
            throw OIDCError.providerError(errorParam)
        }

        guard let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value
        else {
            throw OIDCError.missingCode
        }

        guard state == oauthState else {
            throw OIDCError.stateMismatch
        }

        guard let verifier = pkceVerifier else { throw OIDCError.missingVerifier }

        try await exchange(code: code, verifier: verifier)
        pkceVerifier = nil
        oauthState = nil
    }

    private func exchange(code: String, verifier: String) async throws {
        let body = formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": environment.oidcRedirectURI,
            "code_verifier": verifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: tokenRequest(body: body))
        try persistTokens(from: data, response: response)
    }

    private func refresh(refreshToken: String) async throws {
        let body = formEncode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let (data, response) = try await URLSession.shared.data(for: tokenRequest(body: body))
        try persistTokens(from: data, response: response)
    }

    /// Build a POST to /oauth2/token with Basic auth using the OIDC client
    /// credentials. Quran Foundation registers ayyat as a *confidential*
    /// client (they issued a client_secret alongside the client_id), so the
    /// token endpoint requires authentication — sending only client_id in
    /// the body returns 401 invalid_client.
    private func tokenRequest(body: String) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let secret = environment.oidcClientSecret
        if !secret.isEmpty {
            let credential = "\(environment.oidcClientId):\(secret)"
            let token = Data(credential.utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body.data(using: .utf8)
        return request
    }

    private var tokenURL: URL {
        URL(string: "\(environment.authBaseURL)/oauth2/token")!
    }

    private func persistTokens(from data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw OIDCError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            dlog("[ayyat] OIDC token exchange failed (\(http.statusCode)): \(body)")
            throw OIDCError.tokenExchangeFailed(http.statusCode)
        }
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)

        self.accessToken = payload.accessToken
        if let r = payload.refreshToken { self.refreshToken = r }
        if let id = payload.idToken { self.idToken = id }
        self.expiresAt = Date().addingTimeInterval(TimeInterval(payload.expiresIn))

        KeychainHelper.save(payload.accessToken, forKey: Keys.accessToken)
        if let r = payload.refreshToken { KeychainHelper.save(r, forKey: Keys.refreshToken) }
        if let id = payload.idToken { KeychainHelper.save(id, forKey: Keys.idToken) }
        KeychainHelper.save(String(Int(expiresAt!.timeIntervalSince1970)), forKey: Keys.expiresAt)
    }

    private func loadFromKeychain() {
        accessToken = KeychainHelper.load(Keys.accessToken)
        refreshToken = KeychainHelper.load(Keys.refreshToken)
        idToken = KeychainHelper.load(Keys.idToken)
        if let s = KeychainHelper.load(Keys.expiresAt), let ts = TimeInterval(s) {
            expiresAt = Date(timeIntervalSince1970: ts)
        }
        if let raw = KeychainHelper.load(Keys.userInfo),
           let data = raw.data(using: .utf8),
           let info = try? JSONDecoder().decode(OIDCUserInfo.self, from: data) {
            userInfo = info
        }
    }

    // MARK: - Helpers

    /// x-www-form-urlencoded body encoder.
    ///
    /// `.urlQueryAllowed` permits `+`, `&`, `=` — but in
    /// application/x-www-form-urlencoded `+` means SPACE on the server side,
    /// so leaving a `+` in a refresh_token / auth_code / verifier corrupts
    /// the value mid-flight (Ory returns `invalid_grant`). We use a stricter
    /// set that mirrors RFC 3986 unreserved characters.
    private func formEncode(_ params: [String: String]) -> String {
        // Unreserved per RFC 3986: ALPHA / DIGIT / "-" / "." / "_" / "~"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { k, v in
            let kEnc = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let vEnc = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(kEnc)=\(vEnc)"
        }.joined(separator: "&")
    }

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private enum Keys {
        static let accessToken = "oidc.access_token"
        static let refreshToken = "oidc.refresh_token"
        static let idToken = "oidc.id_token"
        static let expiresAt = "oidc.expires_at"
        static let userInfo = "oidc.user_info"
    }
}

/// OIDC `/userinfo` response. Minimal — only the fields we actually
/// display. Tolerant decoder so a missing email or name doesn't fail.
struct OIDCUserInfo: Codable, Sendable {
    let sub: String?
    let email: String?
    let emailVerified: Bool?
    let name: String?
    let givenName: String?
    let familyName: String?
    let picture: String?

    enum CodingKeys: String, CodingKey {
        case sub, email, name, picture
        case emailVerified = "email_verified"
        case givenName = "given_name"
        case familyName = "family_name"
    }

    /// Best-effort display name for the Settings row.
    var displayName: String? {
        if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        if let first = givenName, let last = familyName { return "\(first) \(last)" }
        return givenName ?? email
    }
}

extension OIDCAuthService: ASWebAuthenticationPresentationContextProviding {
    /// Apple guarantees this delegate method is invoked on the main thread.
    /// Wrapping with `DispatchQueue.main.sync` from a nonisolated entry
    /// point deadlocks (and traps under Swift 6 strict concurrency), so we
    /// assume MainActor isolation directly.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
                ?? ASPresentationAnchor()
        }
    }
}

enum OIDCError: LocalizedError {
    case invalidAuthURL
    case noCallbackURL
    case invalidCallback
    case missingCode
    case missingVerifier
    case stateMismatch
    case providerError(String)
    case tokenExchangeFailed(Int)
    case invalidResponse
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .invalidAuthURL: "Could not construct authorization URL"
        case .noCallbackURL: "Sign in was cancelled"
        case .invalidCallback: "Invalid callback URL"
        case .missingCode: "Authorization code missing from callback"
        case .missingVerifier: "PKCE verifier missing"
        case .stateMismatch: "OAuth state mismatch (possible CSRF)"
        case .providerError(let m): "Provider error: \(m)"
        case .tokenExchangeFailed(let c): "Token exchange failed (HTTP \(c))"
        case .invalidResponse: "Invalid response from auth server"
        case .notSignedIn: "Not signed in"
        }
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresIn: Int
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
