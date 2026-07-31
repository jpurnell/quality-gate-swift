import Foundation
import Testing
import QualityGateCore
@testable import KeychainSecretsChecker

/// The `keychain-secrets` checker (KeychainSecretsChecker proposal, Phase 0).
///
/// Contract under test: a `UserDefaults` `set`/`setValue`/subscript write whose
/// key literal names a secret gates at the configured severity (default
/// `.error`); a secret seen only in the stored value's identifier softens to
/// `.warning`; a stored `Bool`/`Int` literal is never flagged; matching is
/// word-aware; non-`UserDefaults` receivers are ignored; and both `allowKeys`
/// and an inline `// keychain:exempt` (recorded, never silent) suppress a site.
@Suite("KeychainSecretsChecker")
struct KeychainSecretsCheckerTests {

    private func analyze(
        _ source: String,
        config: KeychainSecretsConfig = KeychainSecretsConfig()
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        KeychainSecretsChecker.analyze(source: source, filePath: "/fixtures/Fixture.swift", config: config)
    }

    // MARK: - Positive detections

    @Test("set(_:forKey:) with a secret string key flags at error")
    func setWithSecretKey() throws {
        let result = analyze("""
        func save(_ accessToken: String) {
            let defaults = UserDefaults.standard
            defaults.set(accessToken, forKey: "authToken")
        }
        """)
        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.ruleId == "keychain-secrets")
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.lineNumber == 3)
        #expect(diagnostic.message.lowercased().contains("keychain"))
    }

    @Test("setValue(_:forKey:) with a secret key flags")
    func setValueWithSecretKey() throws {
        let result = analyze("""
        func save(_ token: String) {
            UserDefaults.standard.setValue(token, forKey: "password")
        }
        """)
        #expect(result.diagnostics.count == 1)
        #expect(try #require(result.diagnostics.first).severity == .error)
    }

    @Test("subscript assignment with a secret key flags")
    func subscriptWithSecretKey() throws {
        let result = analyze("""
        func save(_ token: String) {
            let defaults = UserDefaults.standard
            defaults["refreshToken"] = token
        }
        """)
        #expect(result.diagnostics.count == 1)
        #expect(try #require(result.diagnostics.first).severity == .error)
    }

    @Test("a UserDefaults(suiteName:) receiver is recognized")
    func suiteNameReceiver() throws {
        let result = analyze("""
        func save(_ token: String) {
            let defaults = UserDefaults(suiteName: "group.app")
            defaults?.set(token, forKey: "clientSecret")
        }
        """)
        #expect(result.diagnostics.count == 1)
        #expect(try #require(result.diagnostics.first).severity == .error)
    }

    @Test("a secret seen only in the value identifier softens to warning")
    func valueIdentifierOnly() throws {
        let result = analyze("""
        func save(_ authToken: String) {
            UserDefaults.standard.set(authToken, forKey: "lastValue")
        }
        """)
        #expect(result.diagnostics.count == 1)
        #expect(try #require(result.diagnostics.first).severity == .warning)
    }

    // MARK: - Precision guards (negative)

    @Test("a stored Bool literal is never flagged, even under a secret-ish key")
    func boolValueGuard() {
        let result = analyze("""
        func save() {
            UserDefaults.standard.set(true, forKey: "hasSeenTokenTutorial")
        }
        """)
        #expect(result.diagnostics.isEmpty)
        #expect(result.overrides.isEmpty)
    }

    @Test("a stored Int literal is never flagged")
    func intValueGuard() {
        let result = analyze("""
        func save() {
            UserDefaults.standard.set(3, forKey: "passwordAttemptCount")
        }
        """)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("a non-UserDefaults receiver named set is ignored")
    func nonUserDefaultsReceiver() {
        let result = analyze("""
        func save(_ password: String) {
            let cache = Cache()
            cache.set(password, forKey: "password")
        }
        """)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("an unrelated method on an unrelated receiver is ignored")
    func unrelatedCall() {
        let result = analyze("""
        func save(_ token: String) {
            keychain.store(token, forKey: "authToken")
        }
        """)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("matching is word-aware: tokenizer is not token")
    func wordBoundary() {
        let result = analyze("""
        func save() {
            UserDefaults.standard.set("v", forKey: "tokenizerConfig")
        }
        """)
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - Configuration

    @Test("allowKeys suppresses an otherwise-flagged key")
    func allowKeysSuppresses() {
        let config = KeychainSecretsConfig(allowKeys: ["apiKeyLabel"])
        let result = analyze("""
        func save() {
            UserDefaults.standard.set("v", forKey: "apiKeyLabel")
        }
        """, config: config)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("extraPatterns adds a project-specific secret noun")
    func extraPatternsAdds() {
        let clean = analyze("""
        func save() {
            UserDefaults.standard.set("v", forKey: "jwtValue")
        }
        """)
        #expect(clean.diagnostics.isEmpty)

        let config = KeychainSecretsConfig(extraPatterns: ["jwt"])
        let flagged = analyze("""
        func save() {
            UserDefaults.standard.set("v", forKey: "jwtValue")
        }
        """, config: config)
        #expect(flagged.diagnostics.count == 1)
    }

    @Test("severity is honored")
    func severityHonored() throws {
        let config = KeychainSecretsConfig(severity: .warning)
        let result = analyze("""
        func save(_ token: String) {
            UserDefaults.standard.set(token, forKey: "password")
        }
        """, config: config)
        #expect(result.diagnostics.count == 1)
        #expect(try #require(result.diagnostics.first).severity == .warning)
    }

    // MARK: - Exemption (recorded, never silent)

    @Test("an inline // keychain:exempt records an override, not a diagnostic")
    func exemptMarkerRecorded() throws {
        let result = analyze("""
        func save(_ token: String) {
            UserDefaults.standard.set(token, forKey: "password") // keychain:exempt
        }
        """)
        #expect(result.diagnostics.isEmpty)
        #expect(result.overrides.count == 1)
        let override = try #require(result.overrides.first)
        #expect(override.ruleId == "keychain-secrets")
        #expect(override.justification.contains("keychain:exempt"))
    }
}
