import Foundation
import SwiftParser
import SwiftSyntax
import Testing
@testable import QualityGateCore
@testable import SafetyAuditor

/// A seed is not a secret.
///
/// Four rules for a value that has to be unpredictable and was made by something predictable:
/// a non-cryptographic generator (`weak-prng`), a generator seeded where the reader can see it
/// (`seeded-secret`), a value built from the clock, the pid or a hash (`predictable-token`), and a
/// UUID standing in for a secret (`uuid-as-secret`, a warning). Each fires only in a security
/// context as `SecurityContext` defines it, so a Monte Carlo draw from a seeded generator stays
/// exactly as wanted as it was.
///
/// See `quality-gate-swift-project/plans/proposals/ASeedIsNotASecret.md` §5; the numbers in the
/// test names are that section's.
@Suite("Randomness rules")
struct RandomnessRulesTests {

    static let weak = "security.weak-prng"
    static let seeded = "security.seeded-secret"
    static let predictable = "security.predictable-token"
    static let uuid = "security.uuid-as-secret"
    static let all = [weak, seeded, predictable, uuid]

    private func audit(_ code: String, configuration: Configuration = Configuration()) async throws -> CheckResult {
        try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: configuration)
    }

    private func findings(_ rule: String, in code: String) async throws -> [Diagnostic] {
        try await audit(code).diagnostics.filter { $0.ruleId == rule }
    }

    /// Every finding of the four rules.
    private func randomnessFindings(in code: String) async throws -> [Diagnostic] {
        try await audit(code).diagnostics.filter { Self.all.contains($0.ruleId ?? "") }
    }

    // MARK: - weak-prng (CWE-338)

    @Test("1. let token = String(drand48()) is an error")
    func drand48Token() async throws {
        let found = try await findings(Self.weak, in: "let token = String(drand48())")
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.lineNumber == 1)
        #expect(found.first?.message.contains("[CWE-338]") == true)
        #expect(found.first?.message.contains("'drand48'") == true)
        #expect(found.first?.message.contains("'token'") == true)
    }

    @Test("2. A session id interpolated from rand() is an error")
    func randSessionID() async throws {
        let found = try await findings(Self.weak, in: #"let sessionID = "\(rand())""#)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("3. A salt mapped from random() is an error")
    func randomSalt() async throws {
        let found = try await findings(
            Self.weak, in: "let salt = (0..<16).map { _ in UInt8(truncatingIfNeeded: random()) }")
        #expect(found.count == 1)
        #expect(found.first?.message.contains("'random'") == true)
    }

    @Test("4. GameplayKit's shared source makes a weak nonce")
    func gameplayKitNonce() async throws {
        let found = try await findings(Self.weak, in: "let nonce = GKRandomSource.sharedRandom().nextInt()")
        #expect(found.count == 1)
        #expect(found.first?.message.contains("'GKRandomSource'") == true)
    }

    @Test("5. A seeded Mersenne Twister is one weak-prng finding, not also seeded-secret")
    func seededTwisterIsOneFinding() async throws {
        let all = try await randomnessFindings(
            in: "let csrfToken = GKMersenneTwisterRandomSource(seed: 42).nextInt()")
        #expect(all.map(\.ruleId) == [Self.weak])
    }

    @Test("6. let jitter = drand48() is not a security context")
    func jitterIsClean() async throws {
        #expect(try await randomnessFindings(in: "let jitter = drand48()").isEmpty)
    }

    @Test("6. A security-named scope alone does not make a context")
    func scopeAloneIsNotAContext() async throws {
        let code = """
            struct AuthService {
                func refreshToken() {
                    let jitter = drand48()
                    sleep(jitter)
                }
            }
            """
        #expect(try await randomnessFindings(in: code).isEmpty)
    }

    @Test("7. arc4random is a safe source")
    func arc4randomIsSafe() async throws {
        #expect(try await randomnessFindings(in: "let token = arc4random()").isEmpty)
    }

    @Test("A local GameplayKit generator drawn into a token is reached through the local")
    func localWeakGenerator() async throws {
        let found = try await findings(Self.weak, in: """
            func makeToken() -> Int {
                let source = GKARC4RandomSource()
                let token = source.nextInt()
                return token
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
    }

    // MARK: - seeded-secret (CWE-335 / 336 / 337)

    @Test("8. A literal seed behind a token is CWE-336")
    func literalSeed() async throws {
        let found = try await findings(Self.seeded, in: """
            var g = SplitMix64(seed: 1)
            let token = generateToken(using: &g)
            """)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.lineNumber == 2)
        #expect(found.first?.message.contains("[CWE-336]") == true)
        #expect(found.first?.message.contains("'g'") == true)
    }

    @Test("9. A clock seed behind a token is CWE-337")
    func clockSeed() async throws {
        let found = try await findings(Self.seeded, in: """
            var g = Xoshiro256StarStar(seed: UInt64(Date().timeIntervalSince1970))
            let token = generateToken(using: &g)
            """)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("[CWE-337]") == true)
    }

    @Test("Any other seed is CWE-335")
    func otherSeed() async throws {
        let found = try await findings(Self.seeded, in: """
            var g = Generator(state: configuredState)
            let nonce = makeNonce(using: &g)
            """)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("[CWE-335]") == true)
    }

    @Test("A generator whose type name says it is deterministic is seeded, CWE-335")
    func deterministicTypeName() async throws {
        let found = try await findings(Self.seeded, in: """
            var g = MockRandomNumberGenerator()
            let salt = makeSalt(using: &g)
            """)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("[CWE-335]") == true)
    }

    @Test("A direct next() on a seeded generator is reported")
    func directNext() async throws {
        let found = try await findings(Self.seeded, in: """
            var g = SplitMix64(seed: 7)
            let nonce = g.next()
            """)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("[CWE-336]") == true)
    }

    @Test("A seeded draw reaches a returned token through a local")
    func seededDrawThroughLocal() async throws {
        let found = try await findings(Self.seeded, in: """
            func makeToken() -> String {
                var g = SplitMix64(seed: 1)
                let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
                return bytes.hexEncoded()
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 3)
        #expect(found.first?.message.contains("'makeToken'") == true)
    }

    @Test("10. SystemRandomNumberGenerator behind a token is clean")
    func systemGeneratorIsSafe() async throws {
        #expect(try await randomnessFindings(in: """
            var g = SystemRandomNumberGenerator()
            let token = generateToken(using: &g)
            """).isEmpty)
    }

    @Test("11. A function taking its caller's generator is not a finding")
    func generatorSeamIsNotAFinding() async throws {
        #expect(try await randomnessFindings(in: """
            func mint<G: RandomNumberGenerator>(using g: inout G) -> Session {
                let token = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
                return Session(token: token)
            }
            """).isEmpty)
    }

    @Test("12. A stored generator is not resolved, so not reported")
    func storedGeneratorIsNotReported() async throws {
        #expect(try await randomnessFindings(in: """
            struct Router {
                var generator: any RandomNumberGenerator
                mutating func issue() -> String {
                    let token = generateToken(using: &self.generator)
                    return token
                }
            }
            """).isEmpty)
    }

    @Test("13. A seeded sample outside a security context stays wanted")
    func seededSampleIsClean() async throws {
        #expect(try await randomnessFindings(in: """
            var g = SplitMix64(seed: 1)
            let sample = Double.random(in: 0...1, using: &g)
            """).isEmpty)
    }

    // MARK: - predictable-token (CWE-341)

    @Test("14. A token made of the clock is an error")
    func clockToken() async throws {
        let found = try await findings(Self.predictable, in: #"let token = "\(Date().timeIntervalSince1970)""#)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.message.contains("[CWE-341]") == true)
    }

    @Test("15. A reset token made of a hashValue is an error")
    func hashValueToken() async throws {
        let found = try await findings(Self.predictable, in: "let resetToken = String(email.hashValue)")
        #expect(found.count == 1)
        #expect(found.first?.message.contains("hashValue") == true)
    }

    @Test("16. An OTP made of the clock is an error")
    func clockOTP() async throws {
        let found = try await findings(
            Self.predictable, in: "let otp = Int(Date().timeIntervalSince1970) % 1_000_000")
        #expect(found.count == 1)
    }

    @Test("17. A nonce made of the pid and the clock is one error")
    func pidAndClockNonce() async throws {
        let found = try await findings(
            Self.predictable, in: #"let nonce = "\(getpid())-\(Date().timeIntervalSince1970)""#)
        #expect(found.count == 1)
    }

    @Test("18. Date() as an argument to some other call is that call's business")
    func dateAsArgument() async throws {
        #expect(try await randomnessFindings(
            in: "let token = try await store.issue(name: name, now: Date())").isEmpty)
    }

    @Test("19. A cache key is not a context: 'key' alone is weak")
    func cacheKey() async throws {
        #expect(try await randomnessFindings(
            in: #"let key = "stock_\(symbol)_\(from.timeIntervalSince1970)""#).isEmpty)
    }

    @Test("20. A descriptor suffix describes a secret and is not one")
    func descriptorSuffix() async throws {
        #expect(try await randomnessFindings(
            in: #"let keyName = "API Key \(Date().formatted(.dateTime))""#).isEmpty)
    }

    @Test("A clock value with a random part is not predictable")
    func clockWithRandomPart() async throws {
        #expect(try await findings(
            Self.predictable,
            in: #"let token = "\(Date().timeIntervalSince1970)-\(UInt64.random(in: 0 ... .max))""#).isEmpty)
    }

    @Test("A bare timestamp is a time, not a token")
    func bareTimestamp() async throws {
        #expect(try await randomnessFindings(in: """
            let sessionStart = Date()
            let sessionStarted = Date.now
            """).isEmpty)
    }

    @Test("The clock reaches a token through a local")
    func clockThroughLocal() async throws {
        let found = try await findings(Self.predictable, in: """
            func makeToken() -> String {
                let stamp = Date().timeIntervalSince1970
                return "tok-\\(stamp)"
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
    }

    @Test("Clock arithmetic is a duration, not a token: HRVKit's training session")
    func clockArithmeticIsADuration() async throws {
        #expect(try await randomnessFindings(in: """
            func tick(settlingStart: ContinuousClock.Instant) {
                let sessionElapsed = ContinuousClock.now - settlingStart
                record(sessionElapsed)
            }
            final class Model {
                var sessionClockStart: ContinuousClock.Instant?
                func start() {
                    var settlingStart = ContinuousClock.now
                    sessionClockStart = settlingStart
                }
            }
            """).isEmpty)
    }

    // MARK: - uuid-as-secret (CWE-340, warning)

    @Test("21. A session id from UUID() is a warning")
    func uuidSessionID() async throws {
        let found = try await findings(Self.uuid, in: "let sessionId = UUID().uuidString")
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("[CWE-340]") == true)
    }

    @Test("22. let id = UUID() is clean")
    func plainID() async throws {
        #expect(try await randomnessFindings(in: "let id = UUID()").isEmpty)
    }

    @Test("23. A request id is not in the vocabulary")
    func requestID() async throws {
        #expect(try await randomnessFindings(in: "let requestID = UUID().uuidString").isEmpty)
    }

    @Test("24. Under weakCryptoPolicy justified, a reason on the line above is recorded")
    func justifiedUUID() async throws {
        var configuration = Configuration()
        configuration.security.weakCryptoPolicy = .justified
        let result = try await audit("""
            // Justification: the session id is a routing key; the bearer token authorises
            let sessionId = UUID().uuidString
            """, configuration: configuration)
        #expect(!result.diagnostics.contains { $0.ruleId == Self.uuid })
        let override = try #require(result.overrides.first { $0.ruleId == Self.uuid })
        #expect(override.lineNumber == 2)
        #expect(override.justification == "the session id is a routing key; the bearer token authorises")
    }

    @Test("24. Under justified, no reason leaves the warning standing")
    func justifiedWithoutReason() async throws {
        var configuration = Configuration()
        configuration.security.weakCryptoPolicy = .justified
        let result = try await audit("let sessionId = UUID().uuidString", configuration: configuration)
        let found = result.diagnostics.filter { $0.ruleId == Self.uuid }
        #expect(found.count == 1)
        #expect(found.first?.message.contains("Justification") == true)
    }

    @Test("25. An API key from UUID() is the same warning")
    func uuidAPIKey() async throws {
        let found = try await findings(Self.uuid, in: "let apiKey = UUID().uuidString")
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
    }

    @Test("A UUID beside the clock is a UUID finding, not a predictable one")
    func uuidBesideClock() async throws {
        let all = try await randomnessFindings(
            in: #"let token = "\(Date().timeIntervalSince1970)-\(UUID().uuidString)""#)
        #expect(all.map(\.ruleId) == [Self.uuid])
    }

    @Test("A UUID as an optional's default is the value: swiftMoE's SessionStore")
    func uuidAsNilCoalescingDefault() async throws {
        let found = try await findings(Self.uuid, in: """
            final class SessionStore {
                let sessionID: String
                init(sessionID: String? = nil) {
                    self.sessionID = sessionID ?? UUID().uuidString
                }
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
    }

    @Test("A UUID as a parameter's default value is the parameter's value: SSESession")
    func uuidAsDefaultArgument() async throws {
        let found = try await findings(Self.uuid, in: """
            struct SSESession {
                init(sessionId: String = UUID().uuidString) {}
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
    }

    @Test("Test code may seed a generator to pin a credential's bytes, and mint UUID sessions")
    func testFilesAreExempt() async throws {
        let code = """
            func testVerifier() {
                var generator = SplitMix64(seed: 1)
                let verifier = PassphraseVerifier(for: "pw", using: &generator)
                let sessionId = UUID().uuidString
            }
            """
        let result = try await SafetyAuditor().auditSource(
            code, fileName: "/repo/Tests/IdentityTests/VerifierTests.swift", configuration: Configuration())
        #expect(!result.diagnostics.contains { Self.all.contains($0.ruleId ?? "") })
        // The same code outside Tests/ is two findings.
        let sources = try await randomnessFindings(in: code).compactMap(\.ruleId)
        #expect(sources == [Self.seeded, Self.uuid])
    }

    // MARK: - Sinks

    @Test("26. A weak value written to a header is an error with no named binding")
    func headerSink() async throws {
        let found = try await findings(
            Self.weak,
            in: #"request.setValue(String(drand48()), forHTTPHeaderField: "X-Request-Token")"#)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("header") == true)
    }

    // MARK: - Vocabulary

    @Test("27. @State var state is not a context")
    func viewState() async throws {
        #expect(try await randomnessFindings(in: """
            struct ContentView: View {
                @State private var state = drand48()
            }
            """).isEmpty)
    }

    @Test("28. state inside OAuthConnection is a context: weak is reported, safe is clean")
    func oauthState() async throws {
        let weakFound = try await findings(Self.weak, in: """
            struct OAuthConnection {
                func begin() -> String {
                    let state = String(drand48())
                    return state
                }
            }
            """)
        #expect(weakFound.count == 1)
        #expect(weakFound.first?.message.contains("OAuthConnection") == true)
        #expect(try await randomnessFindings(in: """
            struct OAuthConnection {
                func begin() -> String {
                    let state = TokenGenerator.generateToken()
                    return state
                }
            }
            """).isEmpty)
    }

    @Test("29. tokenizer is not token")
    func tokenizer() async throws {
        #expect(try await randomnessFindings(in: """
            var tokenizer = SplitMix64(seed: 1)
            let tokenizerOutput = Tokenizer(using: &tokenizer)
            """).isEmpty)
    }

    // MARK: - What is safe, so the rules can be seen to clear

    @Test("Safe sources in a security context are clean", arguments: [
        "let token = UInt64.random(in: .min ... .max)",
        "let status = SecRandomCopyBytes(kSecRandomDefault, 32, &secretBytes)",
        "let encryptionKey = SymmetricKey(size: .bits256)",
        "let nonce = AES.GCM.Nonce()",
        "let nonce = ChaChaPoly.Nonce()",
        "let privateKey = P256.Signing.PrivateKey()",
        "let salt = arc4random_uniform(100)",
    ])
    func safeSources(code: String) async throws {
        #expect(try await randomnessFindings(in: code).isEmpty)
    }

    // MARK: - enabledRules

    @Test("A rule left out of enabledRules does not run")
    func enabledRules() async throws {
        var configuration = Configuration()
        configuration.security.enabledRules = [Self.predictable]
        let result = try await audit("""
            let token = String(drand48())
            let otp = Int(Date().timeIntervalSince1970) % 1_000_000
            """, configuration: configuration)
        let ruleIds = result.diagnostics.compactMap(\.ruleId).filter { Self.all.contains($0) }
        #expect(ruleIds == [Self.predictable])
    }

    // MARK: - SecurityValueSite, as its documentation shows it

    @Test("resolve climbs from a reference through the call and String(…) to the binding")
    func resolveFromReference() throws {
        let tree = Parser.parse(source: "let token = String(drand48())")
        let name = try #require(tree.tokens(viewMode: .sourceAccurate).first { $0.text == "drand48" })
        let reference = try #require(name.parent)
        let resolution = try #require(SecurityValueSite.resolve(reference))
        #expect(resolution.verdict == .named(term: "token"))
        #expect(resolution.site.destination == .binding(name: "token"))
        #expect(resolution.via == [])
    }

    @Test("resolve names the locals a value passed through")
    func resolveThroughLocals() throws {
        let tree = Parser.parse(source: """
            func makeToken() -> String {
                var g = SystemRandomNumberGenerator()
                let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
                return bytes.hexEncoded()
            }
            """)
        let name = try #require(tree.tokens(viewMode: .sourceAccurate).first { $0.text == "SystemRandomNumberGenerator" })
        let reference = try #require(name.parent)
        let resolution = try #require(SecurityValueSite.resolve(reference))
        #expect(resolution.site.destination == .returned(fromFunction: "makeToken"))
        #expect(resolution.via == ["g", "bytes"])
    }

    // MARK: - Coverage counts (§3.8)

    @Test("The visitor counts what it examined, by outcome")
    func coverageCounts() {
        let code = """
            func a() { let token = String(drand48()) }
            func b() { let otp = Int(Date().timeIntervalSince1970) % 1_000_000 }
            func c() { let sessionId = UUID().uuidString }
            func d() { let nonce = UInt64.random(in: 0 ... .max) }
            struct R {
                var generator: any RandomNumberGenerator
                mutating func e() { let token = generateToken(using: &self.generator) }
            }
            func makeSessionToken<G: RandomNumberGenerator>(using g: inout G) -> String { "" }
            func shuffle<G: RandomNumberGenerator>(_ deck: [Int], using g: inout G) -> [Int] { deck }
            func f() { let jitter = drand48() }
            """
        let tree = Parser.parse(source: code)
        let visitor = SecurityVisitor(
            fileName: "test.swift", source: code,
            converter: SourceLocationConverter(fileName: "test.swift", tree: tree),
            configuration: SecurityAuditorConfig(), sourceFile: tree)
        visitor.walk(tree)
        #expect(visitor.randomnessSites == RandomnessSiteCounts(
            examined: 5, safe: 1, weak: 1, predictable: 1, uuid: 1, unresolvedGenerator: 1, generatorSeams: 1))
    }

    @Test("The note states every count, and is absent when no rule runs")
    func coverageNote() {
        let counts = RandomnessSiteCounts(
            examined: 19, safe: 11, weak: 0, predictable: 0, uuid: 4, unresolvedGenerator: 4, generatorSeams: 14)
        let note = SafetyAuditor.randomnessNote(sites: counts, security: SecurityAuditorConfig())
        #expect(note?.severity == .note)
        #expect(note?.ruleId == "security.randomness-coverage")
        #expect(note?.message == "security examined 19 security-named values · 11 from a safe source · 0 weak · "
            + "0 predictable · 4 UUID · 4 from a generator this file cannot resolve · "
            + "14 credential-producing functions accept a caller's generator")

        var off = SecurityAuditorConfig()
        off.enabledRules = ["security.ssrf"]
        #expect(SafetyAuditor.randomnessNote(sites: counts, security: off) == nil)
    }
}
