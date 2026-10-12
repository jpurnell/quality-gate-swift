import Foundation
import Testing
@testable import QualityGateCore

/// The shared security-context predicate (`ASeedIsNotASecret.md` §3.1, §3.6).
///
/// Contract under test: a value is in a security context when it is bound to, passed under,
/// or returned from a name carrying a strong security word with no descriptor; or when that
/// name carries only a weak word (`key`, `state`, `pin`) and an enclosing function or type is
/// named for security; or when it is the value argument of a header, cookie or query sink.
/// Nothing else — and in particular an enclosing scope alone is not sufficient.
@Suite("SecurityContext")
struct SecurityContextTests {

    private func site(
        _ destination: SecurityContext.Destination,
        functions: [String] = [],
        types: [String] = []
    ) -> SecurityContext.Site {
        SecurityContext.Site(destination: destination, enclosingFunctions: functions, enclosingTypes: types)
    }

    // MARK: - Clause (a): a strong word in the destination's name

    @Test("a binding named with a strong word is a context", arguments: [
        "token", "sessionID", "salt", "nonce", "csrfToken", "otp", "resetToken",
        "apiKey", "password", "codeVerifier", "challenge", "iv", "signingKey",
    ])
    func strongBinding(name: String) {
        guard case .named = SecurityContext.evaluate(site(.binding(name: name))) else {
            Issue.record("\(name) is not a named security context")
            return
        }
        #expect(SecurityContext.isSecurityContext(site(.binding(name: name))))
    }

    @Test("the verdict names the word that decided it")
    func verdictNamesTheWord() {
        #expect(SecurityContext.evaluate(site(.binding(name: "csrfToken"))) == .named(term: "token"))
        #expect(SecurityContext.evaluate(site(.argument(label: "nonce"))) == .named(term: "nonce"))
        #expect(SecurityContext.evaluate(site(.returned(fromFunction: "generateToken"))) == .named(term: "token"))
    }

    @Test("an argument label or a function's name is a destination like a binding")
    func labelsAndReturns() {
        #expect(SecurityContext.isSecurityContext(site(.argument(label: "salt"))))
        #expect(SecurityContext.isSecurityContext(site(.returned(fromFunction: "makeSessionID"))))
        #expect(!SecurityContext.isSecurityContext(site(.argument(label: "count"))))
        #expect(!SecurityContext.isSecurityContext(site(.returned(fromFunction: "makeRequestID"))))
    }

    @Test("a name with no security word is not a context", arguments: [
        "jitter", "id", "requestID", "sample", "seed", "tokenizer", "keyboard",
        "secretary", "passwordless", "email",
    ])
    func notAContext(name: String) {
        #expect(!SecurityContext.isSecurityContext(site(.binding(name: name))))
    }

    // MARK: - Descriptors disqualify

    @Test("a descriptor of a secret is not a context", arguments: [
        "keyName", "tokenCount", "sessionExpiry", "challengeIndex", "tokenLength",
        "apiKeyLabel", "maxTokens", "tokenTTL", "passwordPath",
    ])
    func descriptorDisqualifies(name: String) {
        #expect(!SecurityContext.isSecurityContext(site(.binding(name: name))))
        // …even inside a security-named scope.
        #expect(!SecurityContext.isSecurityContext(site(
            .binding(name: name), functions: ["issueToken"], types: ["OAuthConnection"])))
    }

    // MARK: - Weak words need a security scope

    @Test("a weak word alone is not a context", arguments: ["key", "state", "pin", "cacheKey"])
    func weakAlone(name: String) {
        #expect(!SecurityContext.isSecurityContext(site(.binding(name: name))))
        #expect(!SecurityContext.isSecurityContext(site(
            .binding(name: name), functions: ["render"], types: ["ContentView"])))
    }

    @Test("a weak word inside a security-named type or function is a context")
    func weakInScope() {
        // ASeedIsNotASecret §5 test 28: `let state = …` inside `struct OAuthConnection`.
        let inOAuth = site(.binding(name: "state"), types: ["OAuthConnection"])
        #expect(SecurityContext.evaluate(inOAuth) == .weakNameInSecurityScope(term: "state", scope: "OAuthConnection"))
        #expect(SecurityContext.isSecurityContext(site(.binding(name: "key"), functions: ["encryptPayload"])))
        #expect(SecurityContext.isSecurityContext(site(.binding(name: "key"), types: ["CryptoBox"])))
        #expect(SecurityContext.isSecurityContext(site(.binding(name: "pin"), functions: ["hashPasscode"])))
        #expect(SecurityContext.isSecurityContext(site(.binding(name: "state"), types: ["PKCEFlow"])))
    }

    @Test("an enclosing security scope alone does not make a context")
    func scopeAloneIsNotEnough() {
        // ASeedIsNotASecret §5 test 6: `let jitter = drand48()` stays clean.
        #expect(!SecurityContext.isSecurityContext(site(
            .binding(name: "jitter"), functions: ["refreshToken"], types: ["AuthService"])))
    }

    @Test("ASeed's vocabulary cases", arguments: [
        // §5 test 27: `@State private var state = ViewState()` — not a context.
        ("state", ["body"], ["ContentView"], false),
        // §5 test 29: `tokenizer` is not `token`.
        ("tokenizer", [], [], false),
        // §5 test 19: a cache key — `key` alone is weak.
        ("key", ["fetch"], ["CachingProvider"], false),
        // §5 test 20: descriptor suffix.
        ("keyName", [], ["MCPServer"], false),
        // §5 test 21 / 25.
        ("sessionId", [], [], true),
        ("apiKey", [], [], true),
    ])
    func aSeedCases(name: String, functions: [String], types: [String], expected: Bool) {
        #expect(SecurityContext.isSecurityContext(site(.binding(name: name), functions: functions, types: types)) == expected)
    }

    // MARK: - Security scope

    @Test("isSecurityScope recognises auth and crypto names by whole word", arguments: [
        ("OAuthConnection", true),
        ("PKCEFlow", true),
        ("AuthService", true),
        ("authenticate", true),
        ("AuthenticationManager", true),
        ("CredentialStore", true),
        ("CryptoBox", true),
        ("encryptPayload", true),
        ("decrypt", true),
        ("CipherSuite", true),
        ("issueToken", true),
        ("TokenGenerator", true),
        ("ContentView", false),
        ("CachingProvider", false),
        ("Author", false),
        ("Cryptic", false),
    ])
    func securityScope(name: String, expected: Bool) {
        #expect(SecurityContext.isSecurityScope(name) == expected)
    }

    // MARK: - Clause (b): sinks

    @Test("header, cookie and query sinks are recognised with the value argument's index", arguments: [
        ("setValue", [nil, "forHTTPHeaderField"] as [String?], SecurityContext.Sink.httpHeader, 0, 1 as Int?),
        ("addValue", [nil, "forHTTPHeaderField"], .httpHeader, 0, 1),
        ("add", ["name", "value"], .httpHeader, 1, 0),
        ("replaceOrAdd", ["name", "value"], .httpHeader, 1, 0),
        ("HTTPCookie", ["properties"], .cookie, 0, nil),
        ("URLQueryItem", ["name", "value"], .urlQuery, 1, 0),
    ])
    func sinkRecognised(callee: String, labels: [String?], kind: SecurityContext.Sink, index: Int, name: Int?) {
        let match = SecurityContext.sink(callee: callee, argumentLabels: labels)
        #expect(match == SecurityContext.SinkMatch(kind: kind, valueArgumentIndex: index, nameArgumentIndex: name))
    }

    /// What a sink is *called* decides whether its value is a security value. A name that
    /// cannot be read (`nil`) is not evidence either way, so it stays in context.
    @Test("a sink carries a security value when its name is a security word, or cannot be read", arguments: [
        ("token", true), ("access_token", true), ("Authorization", true), ("X-API-Key", true),
        ("X-CSRF-Token", true), ("nonce", true), ("state", false), ("Cookie", true),
        ("period1", false), ("interval", false), ("Content-Type", false), ("User-Agent", false),
        ("If-Modified-Since", false), ("email", false), ("tokenizer", false),
    ])
    func sinkName(name: String, carries: Bool) {
        #expect(SecurityContext.sinkCarriesSecurityValue(named: name) == carries)
    }

    @Test("a sink whose name is not a literal carries a security value")
    func unreadableSinkName() {
        #expect(SecurityContext.sinkCarriesSecurityValue(named: nil) == true)
    }

    @Test("near-miss calls are not sinks", arguments: [
        ("setValue", [nil, "forKey"] as [String?]),
        ("add", [nil]),
        ("add", ["name", "values"]),
        ("URLQueryItem", ["name"]),
        ("HTTPCookie", ["name"]),
        ("append", [nil]),
    ])
    func sinkNearMiss(callee: String, labels: [String?]) {
        #expect(SecurityContext.sink(callee: callee, argumentLabels: labels) == nil)
    }

    @Test("a sink value is a context with no name needed")
    func sinkIsAContext() {
        // ASeedIsNotASecret §5 test 26.
        let sinkSite = site(.sink(.httpHeader))
        #expect(SecurityContext.evaluate(sinkSite) == .sink(.httpHeader))
        #expect(SecurityContext.isSecurityContext(sinkSite))
    }
}
