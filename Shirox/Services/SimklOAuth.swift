import Foundation
import CryptoKit
import Security

/// The rules of Simkl's AUTH V2, with no network and no state.
///
/// V2 arrived on 2026-09-18 and V1 — five-year tokens, no refresh, no scopes — is retired around
/// April 2027. A V1 `client_id` cannot be upgraded; V2 is a separate registration. Each rule here
/// fails quietly when wrong, so each is pinned by `SimklOAuthTests` rather than discovered
/// against a live account.
enum SimklOAuth {
    static let issuer = "https://simkl.com"
    /// On simkl.com. The same path on api.simkl.com 404s.
    static let authorizeEndpoint = URL(string: "https://simkl.com/oauth2/authorize")!
    static let tokenEndpoint = URL(string: "https://api.simkl.com/oauth2/token")!
    static let revokeEndpoint = URL(string: "https://api.simkl.com/oauth2/revoke")!

    /// Omitting `scope`, or misspelling it, grants read-only — and that is not an error. The
    /// sign-in succeeds and every write then fails with `403 insufficient_scope`.
    static let requestedScope = "media:read media:write"

    /// Refresh this long before expiry — Simkl's guidance is "a day or so".
    static let refreshLeadTime: TimeInterval = 24 * 60 * 60

    // MARK: - Authorize

    static func authorizeURL(clientId: String, redirectURI: String,
                             codeChallenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: requestedScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    enum Callback: Equatable {
        case code(String)
        /// The user declined on Simkl's consent page.
        case denied
        /// Not a callback this session can trust, or one carrying an error.
        case rejected(String)
    }

    static func parseCallback(_ url: URL, expectedState: String?) -> Callback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        // State first: a callback that doesn't belong to this flow says nothing trustworthy,
        // including whether the user declined.
        guard let expectedState, value("state") == expectedState else { return .rejected("state mismatch") }
        // Simkl advertises `authorization_response_iss_parameter_supported`, so per RFC 9207 a
        // missing issuer is refused as firmly as a wrong one. It stops a code minted by another
        // authorization server being replayed into this flow.
        guard value("iss") == issuer else { return .rejected("issuer mismatch") }
        if value("error") == "access_denied" { return .denied }
        if let error = value("error") { return .rejected(error) }
        guard let code = value("code"), !code.isEmpty else { return .rejected("no code") }
        return .code(code)
    }

    // MARK: - Token

    /// RFC 6749 §5.1, identical in shape for every grant.
    struct TokenResponse: Decodable, Equatable {
        let access_token: String
        let token_type: String
        /// Always 604800 — seven days.
        let expires_in: Int
        /// Non-rotating: a refresh returns the same string, its 180-day window slid forward.
        let refresh_token: String
        /// Exactly `media:read` or `media:read media:write`, whatever was asked for.
        let scope: String
    }

    static func grantsWrite(_ scope: String) -> Bool {
        scope.split(separator: " ").contains("media:write")
    }

    static func authorizationCodeBody(clientId: String, code: String,
                                      redirectURI: String, verifier: String) -> Data {
        formBody([("grant_type", "authorization_code"), ("client_id", clientId), ("code", code),
                  ("redirect_uri", redirectURI), ("code_verifier", verifier)])
    }

    static func refreshBody(clientId: String, refreshToken: String) -> Data {
        formBody([("grant_type", "refresh_token"), ("client_id", clientId),
                  ("refresh_token", refreshToken)])
    }

    static func revokeBody(clientId: String, token: String) -> Data {
        formBody([("client_id", clientId), ("token", token)])
    }

    /// `application/x-www-form-urlencoded`, escaping everything outside RFC 3986's unreserved
    /// set. `URLComponents` leaves `+` bare, which a form decoder reads as a space.
    static func formBody(_ pairs: [(String, String)]) -> Data {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        return Data(pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }

    // MARK: - Tokens at rest

    /// V2 access tokens are `simkl_at_`-prefixed; V1 tokens are 64 hex characters, unprefixed.
    static func isV2AccessToken(_ token: String) -> Bool { token.hasPrefix("simkl_at_") }

    /// Whether to refresh before the next request. An unknown expiry refreshes: that costs one
    /// request, and the alternative is a 401 in the middle of whatever the user was doing.
    static func needsRefresh(expiry: Date?, now: Date = Date()) -> Bool {
        guard let expiry else { return true }
        return expiry.timeIntervalSince(now) <= refreshLeadTime
    }

    // MARK: - PKCE

    /// base64url(SHA-256(verifier)), no padding. S256 is the only method V2 accepts.
    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes → 43 characters. nil if the system RNG fails, rather than the all-zero
    /// buffer, which would be a valid-looking and entirely predictable verifier.
    static func makeCodeVerifier() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Errors

    /// A Simkl error body's machine-readable `error`. Simkl says to branch on this, never on
    /// `message` or `error_description`, which may change.
    static func errorCode(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }
}
