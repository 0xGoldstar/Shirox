import XCTest
@testable import Shirox

/// AUTH V2's rules, asserted without a network. Each one fails quietly when wrong: an omitted
/// scope signs in fine and then refuses every write; a missing issuer check is invisible until
/// someone uses it; a PKCE mismatch burns the authorization code on every attempt.
final class SimklOAuthTests: XCTestCase {

    private let redirect = "shirox://auth-simkl"

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    private func authorize() -> URL {
        SimklOAuth.authorizeURL(clientId: "cid", redirectURI: redirect, codeChallenge: "ch", state: "st")
    }

    // MARK: - Authorize

    /// The consent page is on simkl.com. Pointed at api.simkl.com it 404s — Simkl calls this the
    /// most common OAuth mistake.
    func testAuthorizeGoesToTheV2PageOnSimklNotTheAPIHost() {
        XCTAssertEqual(authorize().host, "simkl.com")
        XCTAssertEqual(authorize().path, "/oauth2/authorize")
    }

    /// THE ONE THAT MATTERS: without media:write the sign-in succeeds and every write is refused.
    func testAuthorizeAsksForWriteAccess() {
        XCTAssertEqual(query(authorize())["scope"], "media:read media:write")
    }

    func testAuthorizeUsesS256AndTheCodeFlow() {
        let q = query(authorize())
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], "ch")
        XCTAssertEqual(q["client_id"], "cid")
        XCTAssertEqual(q["redirect_uri"], redirect)
        XCTAssertEqual(q["state"], "st")
    }

    // MARK: - PKCE

    /// RFC 7636 Appendix B. Simkl's PKCE page cites the same pair as the self-check.
    func testChallengeMatchesTheRFCVector() {
        XCTAssertEqual(SimklOAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    /// A malformed verifier reports `invalid_grant`, the same as a wrong one, and consumes the code.
    func testVerifierIsInsideTheV2LengthAndAlphabet() throws {
        let verifier = try XCTUnwrap(SimklOAuth.makeCodeVerifier())
        XCTAssertTrue((43...128).contains(verifier.count))
        let alphabet = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertNil(verifier.rangeOfCharacter(from: alphabet.inverted))
    }

    // MARK: - Callback

    private func callback(_ query: String) -> URL { URL(string: "\(redirect)?\(query)")! }
    private let iss = "iss=https%3A%2F%2Fsimkl.com"

    func testAMatchingCallbackYieldsTheCode() {
        XCTAssertEqual(SimklOAuth.parseCallback(callback("code=abc&state=s1&\(iss)"), expectedState: "s1"),
                       .code("abc"))
    }

    func testAForeignStateIsRejected() {
        XCTAssertEqual(SimklOAuth.parseCallback(callback("code=abc&state=s2&\(iss)"), expectedState: "s1"),
                       .rejected("state mismatch"))
    }

    func testACallbackWithNoFlowInProgressIsRejected() {
        XCTAssertEqual(SimklOAuth.parseCallback(callback("code=abc&state=s1&\(iss)"), expectedState: nil),
                       .rejected("state mismatch"))
    }

    /// Simkl's discovery document advertises `iss`, so RFC 9207 requires refusing a callback
    /// without it — not only one carrying the wrong value.
    func testAWrongOrMissingIssuerIsRejected() {
        let wrong = callback("code=abc&state=s1&iss=https%3A%2F%2Fevil.example")
        XCTAssertEqual(SimklOAuth.parseCallback(wrong, expectedState: "s1"), .rejected("issuer mismatch"))
        XCTAssertEqual(SimklOAuth.parseCallback(callback("code=abc&state=s1"), expectedState: "s1"),
                       .rejected("issuer mismatch"))
    }

    func testDeclineIsReportedAsDeniedNotAnError() {
        XCTAssertEqual(SimklOAuth.parseCallback(callback("error=access_denied&state=s1&\(iss)"), expectedState: "s1"),
                       .denied)
    }

    // MARK: - Token response

    /// Simkl's documented example, verbatim.
    func testTokenResponseDecodesSimklsExample() throws {
        let json = #"{"access_token":"simkl_at_EXAMPLEACCESSTOKENVALUE00000000000","token_type":"Bearer","expires_in":604800,"refresh_token":"simkl_rt_EXAMPLEREFRESHTOKENVALUE0000000000","scope":"media:read media:write"}"#
        let tokens = try JSONDecoder().decode(SimklOAuth.TokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(tokens.expires_in, 604800)
        XCTAssertTrue(tokens.refresh_token.hasPrefix("simkl_rt_"))
        XCTAssertTrue(SimklOAuth.grantsWrite(tokens.scope))
    }

    func testReadOnlyScopeDoesNotGrantWrite() {
        XCTAssertFalse(SimklOAuth.grantsWrite("media:read"))
        XCTAssertFalse(SimklOAuth.grantsWrite(""))
    }

    func testRefreshBodyIsFormEncodedWithTheRefreshGrant() {
        let body = String(decoding: SimklOAuth.refreshBody(clientId: "cid", refreshToken: "simkl_rt_x"), as: UTF8.self)
        XCTAssertEqual(body, "grant_type=refresh_token&client_id=cid&refresh_token=simkl_rt_x")
    }

    /// `+` must be escaped: a form decoder reads a bare `+` as a space.
    func testFormBodyEscapesReservedCharacters() {
        let body = String(decoding: SimklOAuth.formBody([("redirect_uri", "shirox://auth-simkl"), ("x", "a+b c")]),
                          as: UTF8.self)
        XCTAssertEqual(body, "redirect_uri=shirox%3A%2F%2Fauth-simkl&x=a%2Bb%20c")
    }

    // MARK: - Tokens at rest

    func testOnlyPrefixedTokensAreV2() {
        XCTAssertTrue(SimklOAuth.isV2AccessToken("simkl_at_0123456789abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(SimklOAuth.isV2AccessToken(String(repeating: "ab", count: 32)))   // V1: 64 hex
    }

    func testRefreshIsDueWithinADayOfExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(SimklOAuth.needsRefresh(expiry: now.addingTimeInterval(2 * 86_400), now: now))
        XCTAssertTrue(SimklOAuth.needsRefresh(expiry: now.addingTimeInterval(12 * 3_600), now: now))
        XCTAssertTrue(SimklOAuth.needsRefresh(expiry: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(SimklOAuth.needsRefresh(expiry: nil, now: now))
    }

    func testErrorCodeIsReadFromTheBody() {
        XCTAssertEqual(SimklOAuth.errorCode(in: Data(#"{"error":"invalid_token","code":401}"#.utf8)), "invalid_token")
        XCTAssertNil(SimklOAuth.errorCode(in: Data("not json".utf8)))
    }
}
