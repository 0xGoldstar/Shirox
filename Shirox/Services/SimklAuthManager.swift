import Foundation
import AuthenticationServices
import CryptoKit
import Security
import Combine

/// Simkl sign-in, over OAuth 2.0 with PKCE.
///
/// No client secret ships. Simkl's PKCE flow replaces it — one of the reasons Simkl was chosen
/// over Trakt, whose token exchange requires a secret that a client app cannot keep.
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

    // Registered at https://simkl.com/settings/developer/ — Redirect URI: shirox://auth-simkl
    // Public by design: it ships in the app and goes on every request as a query parameter.
    // PKCE replaces the client secret; there is no secret to add here.
    let clientId = "050302bd80ca6d64ea0b8b94af52bcd602f3fbb411a96fb042b5ef04fda2b136"
    private let redirectURI = "shirox://auth-simkl"

    private let accessTokenKey = "simkl_access_token"
    private let profileKey = "simkl_user_profile"
    private var codeVerifier: String?
    private var expectedState: String?
    private var authSession: ASWebAuthenticationSession?
    nonisolated(unsafe) var presentationAnchorWindow: ASPresentationAnchor?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
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
        if keychainRead(key: accessTokenKey) != nil {
            isLoggedIn = true
            restoreCachedProfile()
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

    /// Simkl wants `client_id`, `app-name` and `app-version` as QUERY PARAMETERS on every
    /// request — not headers. That differs from both AniList and MyAnimeList, and calls without
    /// them are rejected, so it lives in one place rather than at each call site.
    func authorizedRequest(path: String, method: String = "GET",
                           query: [URLQueryItem] = [],
                           body: [String: Any]? = nil) throws -> URLRequest {
        var components = URLComponents(string: "https://api.simkl.com\(path)")!
        components.queryItems = query + [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "app-name", value: Self.appName),
            URLQueryItem(name: "app-version", value: Self.appVersion),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Simkl requires a descriptive User-Agent on every request, alongside the query
        // parameters above. Their example is "PlexMediaServer/1.43.1.10540".
        request.setValue("Shirox/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        if let token = keychainRead(key: accessTokenKey) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        // One line per session, so the parameters Simkl attributes traffic by can be confirmed
        // from a log rather than assumed.
        if !Self.loggedSampleURL {
            Self.loggedSampleURL = true
            Logger.shared.log(
                "[Simkl] request url: \(components.url?.absoluteString ?? "-") "
                + "ua=Shirox/\(Self.appVersion)",
                type: "Provider")
        }
        return request
    }

    private nonisolated(unsafe) static var loggedSampleURL = false

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Self.base64URL(Data(bytes))
    }

    /// Simkl requires S256 — a SHA-256 of the verifier, base64url-encoded.
    ///
    /// `MALAuthManager` uses `code_challenge_method=plain`, where the challenge *is* the
    /// verifier unhashed. Copying that shape here produces a challenge Simkl rejects.
    private func codeChallenge(for verifier: String) -> String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Login

    func login(presentationAnchor: ASPresentationAnchor) {
        presentationAnchorWindow = presentationAnchor
        let verifier = generateCodeVerifier()
        let state = UUID().uuidString
        codeVerifier = verifier
        expectedState = state

        var components = URLComponents(string: "https://simkl.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "app-name", value: Self.appName),
            URLQueryItem(name: "app-version", value: Self.appVersion),
        ]

        let webSession = ASWebAuthenticationSession(
            url: components.url!, callbackURLScheme: "shirox"
        ) { [weak self] callbackURL, error in
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
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let verifier = codeVerifier else { return }

        // Reject a callback whose state is not the one this session sent.
        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard returnedState == expectedState else {
            Logger.shared.log("[Simkl] Ignored callback with mismatched state", type: "Error")
            return
        }

        do {
            try await exchangeCode(code, verifier: verifier)
            await fetchCurrentUser()
            // Simkl's documented flow starts here: on connect, download the full watchlist once.
            // Everything after this is an activities check and a `date_from` delta.
            await SimklLibraryService.shared.primeLibrary()
        } catch {
            Logger.shared.log("[Simkl] Auth failed: \(error)", type: "Error")
        }
        codeVerifier = nil
        expectedState = nil
    }

    private func exchangeCode(_ code: String, verifier: String) async throws {
        // Carries the same identification as every other call. This one built its own request
        // and sent none of it — no query parameters and no User-Agent — so the very first call
        // a new user makes was unattributable in Simkl's developer analytics.
        var components = URLComponents(string: "https://api.simkl.com/oauth/token")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "app-name", value: Self.appName),
            URLQueryItem(name: "app-version", value: Self.appVersion),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Shirox/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "client_id": clientId,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])

        let (data, _) = try await session.data(for: request)
        struct TokenResponse: Decodable { let access_token: String }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        keychainWrite(key: accessTokenKey, value: token.access_token)
        isLoggedIn = true
    }

    // MARK: - Profile

    /// `/users/settings` is a POST that takes no body — Simkl notes this is historical rather
    /// than meaningful.
    func fetchCurrentUser() async {
        do {
            let request = try authorizedRequest(path: "/users/settings", method: "POST")
            let (data, _) = try await session.data(for: request)
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

    func logout() {
        keychainDelete(key: accessTokenKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        isLoggedIn = false
        username = nil
        avatarURL = nil
        userId = nil
        accountType = nil
    }
}

#if !os(tvOS)
extension SimklAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchorWindow ?? ASPresentationAnchor()
    }
}
#endif
