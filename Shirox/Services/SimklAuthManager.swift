import Foundation
import AuthenticationServices
import Security
import Combine

/// Simkl sign-in over AUTH V2: OAuth 2.0 with PKCE, scopes and refresh tokens.
///
/// No client secret ships — a "Mobile, desktop & browser apps" registration has none, and PKCE
/// replaces it. The protocol rules live in `SimklOAuth`; this class holds the session.
@MainActor
final class SimklAuthManager: NSObject, ObservableObject {
    static let shared = SimklAuthManager()

    @Published var isLoggedIn = false
    @Published var username: String?
    @Published var avatarURL: String?
    @Published var userId: Int?
    /// "free", "pro" or "vip". Rewatch tracking is Pro-only and silently records *nothing* on a
    /// free account, so a run must not claim it recorded one.
    @Published var accountType: String?
    /// Signed in, but Simkl refused a write for lack of `media:write`. Only a new sign-in fixes
    /// that: a grant's scope can never widen, not even on refresh.
    @Published var needsReauthorization = false

    // Must be an AUTH V2 registration — "Mobile, desktop & browser apps", Redirect URI
    // shirox://auth-simkl. Every /oauth2/* endpoint refuses a V1 client id with 401
    // invalid_client. Public by design: a V2 client id alone reaches only public catalog data.
    let clientId = "69f6182a4823d2a442052d70f2725424420fc9c5b029cb039453a860649611be"
    private let redirectURI = "shirox://auth-simkl"

    private let accessTokenKey = "simkl_access_token"
    private let refreshTokenKey = "simkl_refresh_token"
    private let tokenExpiryKey = "simkl_token_expiry"
    private let profileKey = "simkl_user_profile"
    /// The Simkl account the queued writes and cached library belong to.
    private let queueOwnerKey = "simkl_queue_owner"
    private var codeVerifier: String?
    private var expectedState: String?
    private var authSession: ASWebAuthenticationSession?
    nonisolated(unsafe) var presentationAnchorWindow: ASPresentationAnchor?
    /// One refresh at a time. Each refresh cancels the previous access token on the spot, so two
    /// racing refreshes would each invalidate what the other just received.
    private var refreshTask: Task<Void, Error>?

    /// Carries every Simkl call, library reads included — `full` reads are large, hence 20 s.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    private struct CachedProfile: Codable {
        let id: Int; let name: String; let avatarURL: String?; let type: String?
    }

    private override init() {
        super.init()
        // See `FreshInstallKeychainPurge`: Keychain tokens outlive the app, so this has to run
        // before the token is read or a reinstall comes up claiming a session nobody opened.
        FreshInstallKeychainPurge.runIfNeeded()
        guard let token = keychainRead(key: accessTokenKey) else { return }
        if SimklOAuth.isV2AccessToken(token) {
            isLoggedIn = true
            restoreCachedProfile()
        } else {
            // A five-year V1 token from before AUTH V2. Simkl support never shipped on V1, so
            // there is nobody to carry across: forget it, and the next sign-in is a V2 grant.
            Logger.shared.log("[Simkl] Dropped a pre-V2 token — sign in again", type: "Info")
            signOutLocally()
        }
    }

    // MARK: - Keychain

    // Copied from `MALAuthManager`'s shape deliberately. AniList, MyAnimeList and Jellyfin each
    // carry their own private copy of these three; a shared store would be a worthwhile cleanup
    // but touches three working auth managers, which is not this change's business.

    private func keychainRead(key: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrAccount: key,
                                      kSecReturnData: true,
                                      kSecMatchLimit: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(key: String, value: String) {
        let data = Data(value.utf8)
        let deleteQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                         kSecAttrAccount: key,
                                         kSecValueData: data,
                                         kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func keychainDelete(key: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - Request building

    /// Simkl's convention: "Short, lowercase identifier for your app". Sent on every request
    /// as a query parameter, and what their developer analytics attributes traffic by.
    static let appName = "shirox"

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static var userAgent: String { "Shirox/\(appVersion)" }

    /// Simkl wants `client_id`, `app-name` and `app-version` as QUERY PARAMETERS on every
    /// request — the token exchange included — so it lives in one place.
    private var identificationQuery: [URLQueryItem] {
        [URLQueryItem(name: "client_id", value: clientId),
         URLQueryItem(name: "app-name", value: Self.appName),
         URLQueryItem(name: "app-version", value: Self.appVersion)]
    }

    func authorizedRequest(path: String, method: String = "GET",
                           query: [URLQueryItem] = [],
                           body: [String: Any]? = nil) throws -> URLRequest {
        var components = URLComponents(string: "https://api.simkl.com\(path)")!
        components.queryItems = query + identificationQuery
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let token = keychainRead(key: accessTokenKey) {
            // Sent exactly as issued: Simkl matches tokens case-sensitively.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if !Self.loggedSampleURL {
            Self.loggedSampleURL = true
            Logger.shared.log(
                "[Simkl] request url: \(components.url?.absoluteString ?? "-") ua=\(Self.userAgent)",
                type: "Provider")
        }
        return request
    }

    private nonisolated(unsafe) static var loggedSampleURL = false

    /// For Simkl's cached catalog endpoints: the identification parameters and User-Agent, and
    /// deliberately **no** Authorization — Simkl asks for it to be left off so the edge can serve
    /// the response, and these calls don't count against the user's allowance.
    func catalogRequest(path: String) -> URLRequest {
        var components = URLComponents(string: "https://api.simkl.com\(path)")!
        components.queryItems = identificationQuery
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Sends an authenticated API request, refreshing ahead of expiry and — once — on a 401.
    ///
    /// A V2 access token lasts seven days, so a 401 is nearly always plain expiry: refresh,
    /// retry, and give up only if the refresh itself is refused. `user_token_required` is the
    /// exception — no token went out at all, which refreshing cannot fix. `build` is called
    /// again for the retry so it picks up the new token.
    func send(_ build: () throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await refreshIfNeeded(force: false)
        var (data, http) = try await perform(try build())
        guard http.statusCode == 401 else { return (data, http) }

        if SimklOAuth.errorCode(in: data) == "user_token_required" {
            Logger.shared.log("[Simkl] 401 user_token_required — a request went out without a token", type: "Error")
            throw ProviderError.unauthenticated
        }
        try await refreshIfNeeded(force: true)
        (data, http) = try await perform(try build())
        if http.statusCode == 401 {
            Logger.shared.log("[Simkl] Still 401 after a refresh — signing out", type: "Error")
            signOutLocally()
            throw ProviderError.unauthenticated
        }
        return (data, http)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.networkError(URLError(.badServerResponse))
        }
        return (data, http)
    }

    // MARK: - Tokens

    private var tokenExpiry: Date? {
        guard UserDefaults.standard.object(forKey: tokenExpiryKey) != nil else { return nil }
        return Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: tokenExpiryKey))
    }

    private func store(_ tokens: SimklOAuth.TokenResponse) {
        keychainWrite(key: accessTokenKey, value: tokens.access_token)
        // Non-rotating, so this rewrites the same value on a refresh. Harmless, and it keeps one
        // path for both grants.
        keychainWrite(key: refreshTokenKey, value: tokens.refresh_token)
        UserDefaults.standard.set(
            Date().addingTimeInterval(TimeInterval(tokens.expires_in)).timeIntervalSince1970,
            forKey: tokenExpiryKey)
    }

    /// Concurrent callers share one in-flight refresh — the same shape as `MALAuthManager`.
    private func refreshIfNeeded(force: Bool) async throws {
        guard isLoggedIn else { throw ProviderError.unauthenticated }
        if !force, !SimklOAuth.needsRefresh(expiry: tokenExpiry) { return }
        if let task = refreshTask {
            try await task.value
            return
        }
        let task = Task<Void, Error> { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        guard let refresh = keychainRead(key: refreshTokenKey) else {
            signOutLocally()
            throw ProviderError.unauthenticated
        }
        let (data, http) = try await perform(tokenRequest(
            SimklOAuth.tokenEndpoint,
            body: SimklOAuth.refreshBody(clientId: clientId, refreshToken: refresh)))
        guard http.statusCode == 200 else {
            let code = SimklOAuth.errorCode(in: data)
            // invalid_grant: revoked under Connected Apps, or unused for 180 days. No retry
            // brings that back. Anything else — a 5xx, a timeout — keeps the session.
            if code == "invalid_grant" || code == "invalid_client" {
                Logger.shared.log("[Simkl] Refresh refused (\(code ?? "?")) — signing out", type: "Error")
                signOutLocally()
                throw ProviderError.unauthenticated
            }
            throw ProviderError.serverError(http.statusCode)
        }
        let tokens = try JSONDecoder().decode(SimklOAuth.TokenResponse.self, from: data)
        store(tokens)
        Logger.shared.log("[Simkl] Access token refreshed (expires in \(tokens.expires_in)s)", type: "Info")
    }

    /// Form-encoded, per the V2 examples, with the same identification as every other call.
    private func tokenRequest(_ endpoint: URL, body: Data) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = identificationQuery
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    /// Revoking either half ends the whole grant. The endpoint answers 200 whatever happened —
    /// RFC 7009 — so there is no success to check: send it and move on.
    private func revoke(_ token: String) async {
        _ = try? await perform(tokenRequest(
            SimklOAuth.revokeEndpoint, body: SimklOAuth.revokeBody(clientId: clientId, token: token)))
    }

    // MARK: - Login

    func login(presentationAnchor: ASPresentationAnchor) {
        guard let verifier = SimklOAuth.makeCodeVerifier() else {
            Logger.shared.log("[Simkl] Could not generate a PKCE verifier", type: "Error")
            return
        }
        presentationAnchorWindow = presentationAnchor
        let state = UUID().uuidString
        codeVerifier = verifier
        expectedState = state

        let url = SimklOAuth.authorizeURL(
            clientId: clientId, redirectURI: redirectURI,
            codeChallenge: SimklOAuth.codeChallenge(for: verifier), state: state)
        let webSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "shirox") { [weak self] callbackURL, error in
            guard let self, let url = callbackURL, error == nil else { return }
            Task { await self.handleCallback(url: url) }
        }
        #if !os(tvOS)
        webSession.presentationContextProvider = self
        webSession.prefersEphemeralWebBrowserSession = false
        #endif
        authSession = webSession
        webSession.start()
    }

    private func handleCallback(url: URL) async {
        defer { codeVerifier = nil; expectedState = nil }
        guard let verifier = codeVerifier else { return }

        switch SimklOAuth.parseCallback(url, expectedState: expectedState) {
        case .denied:
            Logger.shared.log("[Simkl] Sign-in declined", type: "Info")
        case .rejected(let reason):
            Logger.shared.log("[Simkl] Ignored sign-in callback: \(reason)", type: "Error")
        case .code(let code):
            do {
                try await exchangeCode(code, verifier: verifier)
                await fetchCurrentUser()
                // Simkl's documented flow starts here: on connect, download the full watchlist
                // once. Everything after is an activities check and a `date_from` delta.
                await SimklLibraryService.shared.primeLibrary()
            } catch {
                Logger.shared.log("[Simkl] Auth failed: \(error)", type: "Error")
            }
        }
    }

    private func exchangeCode(_ code: String, verifier: String) async throws {
        let (data, http) = try await perform(tokenRequest(
            SimklOAuth.tokenEndpoint,
            body: SimklOAuth.authorizationCodeBody(
                clientId: clientId, code: code, redirectURI: redirectURI, verifier: verifier)))
        guard http.statusCode == 200 else {
            Logger.shared.log(
                "[Simkl] Code exchange failed: HTTP \(http.statusCode) \(SimklOAuth.errorCode(in: data) ?? "")",
                type: "Error")
            throw ProviderError.serverError(http.statusCode)
        }
        let tokens = try JSONDecoder().decode(SimklOAuth.TokenResponse.self, from: data)
        guard SimklOAuth.grantsWrite(tokens.scope) else {
            // Signed in but read-only: every write would come back 403. Failing sign-in visibly
            // beats looking connected and syncing nothing.
            Logger.shared.log("[Simkl] Granted '\(tokens.scope)' without media:write — not keeping it", type: "Error")
            await revoke(tokens.refresh_token)
            throw ProviderError.unauthenticated
        }
        store(tokens)
        needsReauthorization = false
        isLoggedIn = true
    }

    // MARK: - Profile

    /// `/users/settings` is a POST that takes no body — Simkl notes this is historical rather
    /// than meaningful.
    func fetchCurrentUser() async {
        do {
            let (data, _) = try await send { try self.authorizedRequest(path: "/users/settings", method: "POST") }
            struct Settings: Decodable {
                struct User: Decodable { let name: String?; let avatar: String? }
                struct Account: Decodable { let id: Int?; let type: String? }
                let user: User?; let account: Account?
            }
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            username = settings.user?.name
            avatarURL = settings.user?.avatar
            userId = settings.account?.id
            accountType = settings.account?.type
            // Queued writes belong to the account that made them. Signing in as somebody else
            // must not deliver the previous account's edits into this one.
            if let id = settings.account?.id {
                if let previous = UserDefaults.standard.object(forKey: queueOwnerKey) as? Int, previous != id {
                    Logger.shared.log("[Simkl] Different account than before — dropping its queue and cache", type: "Info")
                    SimklLibraryService.shared.resetForAccountChange()
                }
                UserDefaults.standard.set(id, forKey: queueOwnerKey)
            }
            cacheProfile()
        } catch {
            Logger.shared.log("[Simkl] Profile fetch failed: \(error)", type: "Error")
        }
    }

    /// Whether this account can record rewatches. Free accounts get silently zeroed counts
    /// rather than an error, so a run must check before claiming it recorded one.
    var supportsRewatch: Bool {
        accountType == "pro" || accountType == "vip"
    }

    private func cacheProfile() {
        guard let userId, let username else { return }
        let profile = CachedProfile(id: userId, name: username, avatarURL: avatarURL, type: accountType)
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    private func restoreCachedProfile() {
        guard let data = UserDefaults.standard.data(forKey: profileKey),
              let profile = try? JSONDecoder().decode(CachedProfile.self, from: data) else { return }
        userId = profile.id
        username = profile.name
        avatarURL = profile.avatarURL
        accountType = profile.type
    }

    // MARK: - Sign out

    /// The user signing out: ends this device's grant at Simkl, then forgets it locally. Queued
    /// writes are kept for the next sign-in — see `SimklWriteQueue`.
    func logout() {
        let refresh = keychainRead(key: refreshTokenKey)
        signOutLocally()
        if let refresh { Task { await revoke(refresh) } }
    }

    /// Forgets the session without contacting Simkl — for a grant Simkl has already refused.
    private func signOutLocally() {
        keychainDelete(key: accessTokenKey)
        keychainDelete(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        isLoggedIn = false
        needsReauthorization = false
        username = nil
        avatarURL = nil
        userId = nil
        accountType = nil
    }
}

#if !os(tvOS)
extension SimklAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { presentationAnchorWindow ?? ASPresentationAnchor() }
    }
}
#endif
