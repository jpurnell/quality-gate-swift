import Foundation

/// Metadata for a single security scanning rule.
///
/// Each rule maps to one or more CWE identifiers and to the OWASP lists that fit it: the Mobile
/// Top 10 (2024), the Top 10 (2021), and the API Security Top 10 (2023). The `lastReviewedDate`
/// field is used by CI staleness checks to ensure rules are periodically reviewed against
/// current Apple SDK APIs.
///
/// One CWE and one OWASP column used to be all a rule could say, and the column was the Mobile
/// list. A server rule has no honest Mobile category, and some rules are more than one
/// weakness — `security.tls-disabled` is improper validation (295) and, for its two
/// `allowsExpired…` forms, improper validation of expiration (298).
///
/// ## Usage
/// ```swift
/// let stale = SecurityRuleManifest.staleRules()
/// for rule in stale {
///     print("\(rule.ruleId) last reviewed \(rule.lastReviewedDate)")
/// }
/// ```
public struct SecurityRule: Sendable, Codable, Equatable {
    /// Machine-readable rule identifier (e.g. "security.hardcoded-secret").
    public let ruleId: String

    /// CWE identifiers, primary first (e.g. `["CWE-295", "CWE-298"]`). Never empty.
    public let cwes: [String]

    /// OWASP Mobile Top 10 (2024) category (e.g. "M1 Improper Credential Usage").
    public let owaspMobile: String

    /// OWASP Top 10 (2021) category, when one fits (e.g. "A03:2021 Injection").
    ///
    /// Taken from MITRE's OWASP Top Ten 2021 view, not assigned by judgement. Written without
    /// parentheses: the staleness workflow reads each `SecurityRule(…)` up to its first `)`.
    public let owaspTop10: String?

    /// OWASP API Security Top 10 (2023) category, when one fits.
    public let owaspAPI: String?

    /// Human-readable description of what the rule detects.
    public let description: String

    /// ISO 8601 date when the rule was last reviewed (YYYY-MM-DD).
    public let lastReviewedDate: String

    /// Number of days after `lastReviewedDate` before the rule is considered stale.
    public let staleAfterDays: Int

    /// Semgrep-compatible severity level.
    public let severity: String

    /// The primary CWE — the first of ``cwes``.
    public var cwe: String { cwes.first ?? "" }

    /// The Mobile category, under its old name.
    @available(*, deprecated, renamed: "owaspMobile")
    public var owaspCategory: String { owaspMobile }

    /// Creates a new security rule definition.
    public init(
        ruleId: String,
        cwes: [String],
        owaspMobile: String,
        owaspTop10: String? = nil,
        owaspAPI: String? = nil,
        description: String,
        severity: String,
        lastReviewedDate: String,
        staleAfterDays: Int = 365
    ) {
        self.ruleId = ruleId
        self.cwes = cwes
        self.owaspMobile = owaspMobile
        self.owaspTop10 = owaspTop10
        self.owaspAPI = owaspAPI
        self.description = description
        self.severity = severity
        self.lastReviewedDate = lastReviewedDate
        self.staleAfterDays = staleAfterDays
    }
}

/// Registry of all security rules with OWASP/CWE mappings and staleness tracking.
///
/// This enum is the single source of truth for security rule metadata.
/// The CI staleness workflow reads `lastReviewedDate` fields to detect
/// rules that need re-evaluation against current Apple SDK APIs.
public enum SecurityRuleManifest {

    /// All registered security rules.
    public static let rules: [SecurityRule] = [
        SecurityRule(
            ruleId: "security.hardcoded-secret",
            cwes: ["CWE-798"],
            owaspMobile: "M1 Improper Credential Usage",
            owaspTop10: "A07:2021 Identification and Authentication Failures",
            description: "Variable named like a secret assigned a string literal",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.command-injection",
            cwes: ["CWE-78"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A03:2021 Injection",
            description: "Shell invoked with -c and a command string assembled at runtime",
            severity: "ERROR",
            lastReviewedDate: "2026-08-18"
        ),
        SecurityRule(
            ruleId: "security.weak-crypto",
            // 328 (Use of Weak Hash), not its parent 327: the rule matches MD5 and SHA-1 and
            // nothing else. 327 is for a cipher rule, when there is one.
            cwes: ["CWE-328"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Use of weak cryptographic hash (MD5/SHA1)",
            severity: "WARNING",
            lastReviewedDate: "2026-10-01"
        ),
        SecurityRule(
            ruleId: "security.broken-cipher",
            // 327 is a Class. Its children were examined first: 328 is hashes, 916 password
            // KDFs, 780 RSA padding — none is "DES". So the Class stays, with the review done.
            cwes: ["CWE-327"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Broken cipher selected: DES, 3DES, RC4, RC2, CAST or Blowfish",
            severity: "ERROR",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.ecb-mode",
            // As broken-cipher: no child of 327 is about a block mode.
            cwes: ["CWE-327"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Block cipher used in ECB mode",
            severity: "ERROR",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.homemade-digest",
            // 1240 is not on any OWASP 2021 list; A02 is assigned by judgement, as the proposal says.
            cwes: ["CWE-1240"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Digest-named function of a secret that calls no cryptographic primitive",
            severity: "WARNING",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.hardcoded-key",
            // 321 is a Variant and a child of 798, which hardcoded-secret claims. One literal is
            // one finding: this rule takes it when the literal is key material.
            cwes: ["CWE-321"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Literal bytes or a PEM private key used as cryptographic key material",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.static-iv",
            // 329 for a CBC IV (CommonCrypto's default mode, AES._CBC, CryptoSwift CBC), 1204 for
            // a fixed IV in any other mode, 323 for a literal or held AEAD nonce. 1204 is not on
            // any OWASP 2021 list; A02 is assigned by judgement, as the proposal says.
            cwes: ["CWE-329", "CWE-1204", "CWE-323"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Encryption with a nil, literal or held IV or nonce",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.weak-kdf",
            // 916: a password stretched too little, or not at all. A digest of a token is not
            // this — a random token has no dictionary to attack.
            cwes: ["CWE-916"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "PBKDF2 below 210,000 rounds, unchecked PBKDF2, or a bare digest of a password",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.weak-key-size",
            // 326 is a Class; no Base child is about key length, so it stays.
            cwes: ["CWE-326"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "RSA key below 2048 bits, or symmetric key below 128 bits",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.insecure-transport",
            cwes: ["CWE-319"],
            owaspMobile: "M5 Insecure Communication",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Insecure HTTP URL detected (use HTTPS)",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.eval-js",
            cwes: ["CWE-95"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A03:2021 Injection",
            description: "WKWebView evaluateJavaScript with dynamic input",
            severity: "ERROR",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.sql-injection",
            cwes: ["CWE-89"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A03:2021 Injection",
            description: "String interpolation passed to SQL-executing function",
            severity: "ERROR",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.insecure-keychain",
            // 922 (Insecure Storage of Sensitive Information). It was 311, "missing
            // encryption", which MITRE marks discouraged for mapping and which is not the
            // defect: the item is encrypted, and readable while the device is locked.
            cwes: ["CWE-922"],
            owaspMobile: "M9 Insecure Data Storage",
            owaspTop10: "A01:2021 Broken Access Control",
            description: "Deprecated insecure Keychain accessibility level",
            severity: "WARNING",
            lastReviewedDate: "2026-10-01"
        ),
        SecurityRule(
            ruleId: "security.tls-disabled",
            cwes: ["CWE-295", "CWE-298"],
            owaspMobile: "M5 Insecure Communication",
            owaspTop10: "A07:2021 Identification and Authentication Failures",
            // Widened 2026-10-02: the three identifiers it matched were in no owned repository,
            // and the one shape that was — NIOSSL's `.none`, three sites — it did not know.
            description: "Certificate validation switched off — URLSession, Security, NIOSSL, AsyncHTTPClient, Alamofire",
            severity: "ERROR",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.tls-no-hostname",
            // 297 is a Variant, the level MITRE prefers for mapping; the chain is checked and
            // the name is not.
            cwes: ["CWE-297"],
            owaspMobile: "M5 Insecure Communication",
            owaspTop10: "A07:2021 Identification and Authentication Failures",
            description: "Certificate validated without checking it against the host",
            severity: "ERROR",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.trust-handler-accepts-all",
            cwes: ["CWE-295"],
            owaspMobile: "M5 Insecure Communication",
            owaspTop10: "A07:2021 Identification and Authentication Failures",
            description: "Server-trust challenge answered with a credential and no evaluation whose result is used",
            severity: "ERROR",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.trust-anchors-widened",
            // A warning permanently: `false` undoes pinning, which is a defect only when
            // pinning was the point, and the call site alone does not say which.
            cwes: ["CWE-295"],
            owaspMobile: "M5 Insecure Communication",
            owaspTop10: "A07:2021 Identification and Authentication Failures",
            description: "Built-in anchor certificates re-enabled on a trust object",
            severity: "WARNING",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.ats-disabled",
            // 319, not 295: ATS decides whether cleartext and weak TLS are permitted. Turning
            // it off leaves certificate validation on an https request untouched. Read from
            // Info.plist by `ATSPolicy`, not by the visitor.
            cwes: ["CWE-319"],
            owaspMobile: "M5 Insecure Communication",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "App Transport Security disabled or excepted in Info.plist",
            severity: "ERROR",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.path-traversal",
            cwes: ["CWE-22"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A01:2021 Broken Access Control",
            description: "Non-literal segment joined onto a directory and used without a containment check",
            severity: "WARNING",
            lastReviewedDate: "2026-10-01"
        ),
        SecurityRule(
            ruleId: "security.path-containment-by-prefix",
            // 187 (Partial String Comparison) is the mechanism; 22 is what it fails to prevent.
            cwes: ["CWE-22", "CWE-187"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A01:2021 Broken Access Control",
            description: "Path containment checked with a string prefix that has no separator",
            severity: "ERROR",
            lastReviewedDate: "2026-10-01"
        ),
        SecurityRule(
            ruleId: "security.archive-path-escape",
            // 22, not its children 23 (relative) and 36 (absolute): an entry name can be either,
            // and MITRE's own observed examples for 22 are the two CVEs it labels "Zip Slip".
            cwes: ["CWE-22"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A01:2021 Broken Access Control",
            description: "Archive entry name joined to a destination and written without a containment check",
            severity: "ERROR",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.archive-symlink",
            // 59 (Link Following), not the composite 61, which describes the attack, not the code.
            cwes: ["CWE-59"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A01:2021 Broken Access Control",
            description: "Symbolic link created from an archive entry with an unchecked target",
            severity: "ERROR",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.regex-catastrophic",
            // 1333 (Base, Allowed). 407 is its Class parent; 400 is Discouraged; 730 Prohibited.
            cwes: ["CWE-1333"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspAPI: "API4:2023 Unrestricted Resource Consumption",
            description: "Literal regular expression with nested or overlapping unbounded repetition",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.regex-from-input",
            // No CWE names regex injection; 1333 by consequence — whoever writes the pattern
            // writes the inefficient one (APatternIsAProgram.md §4.2).
            cwes: ["CWE-1333"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspAPI: "API4:2023 Unrestricted Resource Consumption",
            description: "Regular expression compiled from external input",
            severity: "WARNING",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.predicate-injection",
            // One rule, both sinks (TheGateIsNotYetAggressive.md §2.1): 943 (Class, reviewed —
            // its children are SQL, LDAP, XPath, XQuery) for NSPredicate, 917 (Base) for
            // NSExpression's evaluated format language. A03 by 917's membership.
            cwes: ["CWE-943", "CWE-917"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A03:2021 Injection",
            description: "NSPredicate or NSExpression format string assembled at runtime",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.ssrf",
            cwes: ["CWE-918"],
            owaspMobile: "M5 Insecure Communication",
            owaspTop10: "A10:2021 Server-Side Request Forgery",
            // Reworked 2026-10-05 (`AURLIsNotARequest.md`): a parse is not a request. Reported
            // where a built URL reaches a call that opens a connection, in this function or
            // through a wrapper the package declares, with no question asked about its host.
            // Reviewed 2026-10-08 (§10–§12): a host carried into a value that is then compared —
            // two `Equatable` origins, a tuple — is a question. Connections to a host *string*
            // were measured across the portfolio and are deliberately not reported.
            description: "URL built from non-literal input reaches a network request with no check on its host "
                + "(warning; error when the input is request content, an MCP argument or bytes from the network)",
            severity: "WARNING",
            lastReviewedDate: "2026-10-08"
        ),
        SecurityRule(
            ruleId: "security.xml-external-entities",
            // 611, not 827 (Improper Control of Document Type Definition) for the DTD flags: 611
            // is what a reader searches for. Both Top 10 and API columns from the proposal's
            // table; MITRE's A05:2021 view lists 611.
            cwes: ["CWE-611"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A05:2021 Security Misconfiguration",
            owaspAPI: "API8:2023 Security Misconfiguration",
            description: "XML parser configured, or defaulted, to load external entities",
            severity: "ERROR",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.xml-entity-expansion",
            // WARNING is the DOM-parse half, which no option clears and stays a warning. The
            // XML_PARSE_HUGE half is reported at error by the visitor.
            cwes: ["CWE-776"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A05:2021 Security Misconfiguration",
            owaspAPI: "API4:2023 Unrestricted Resource Consumption",
            description: "XML DOM parse with no DTD refusal, or libxml2 size limits removed",
            severity: "WARNING",
            lastReviewedDate: "2026-10-02"
        ),
        SecurityRule(
            ruleId: "security.bind-all-interfaces",
            // 1327 is the Base; its parent 668 (Exposure of Resource to Wrong Sphere) is
            // Discouraged. ERROR is the literal at the bind, which a caller cannot narrow; a
            // default, assignment or argument is reported at warning by the rule.
            // No Top 10 2021 category: MITRE's view lists neither 1327 nor its parents. The
            // proposal's A05 was judgement, and this column is not.
            cwes: ["CWE-1327"],
            owaspMobile: "M8 Security Misconfiguration",
            owaspAPI: "API8:2023 Security Misconfiguration",
            description: "Listener bound to every interface by a literal, a default or an argument",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.listener-auth-optional",
            // 1188, not 306: the code is not missing a check, it defaults out of one; 306 is the
            // consequence and is named in the message. 306 stays a gap until a handler rule
            // (`unprotected-handler`) reaches it. Not in MITRE's Top 10 2021 view either.
            cwes: ["CWE-1188"],
            owaspMobile: "M3 Insecure Authentication/Authorization",
            owaspAPI: "API2:2023 Broken Authentication",
            description: "Authentication off by default, or switchable off from the environment, in a target that listens",
            severity: "WARNING",
            lastReviewedDate: "2026-10-03"
        ),
        // The advisory rules (AnAdvisoryIsADatedFact.md). The first entries here that are not
        // `security.*` and not emitted by SecurityVisitor: `dependency-advisory` emits them, and
        // the weakness is in what is pinned rather than in what is written. 1395 is a Class with
        // no Base children; MITRE calls it the best available CWE when nothing more specific
        // fits, and nothing does. 1357 is its parent and 1104 is about maintenance, which no
        // lockfile shows. Reviewed every 180 days, not 365: the OSV name convention these depend
        // on is undocumented in the detail that matters and has been observed to vary, and the
        // table of packages that moved from apple/ to swiftlang/ is a list that goes stale.
        SecurityRule(
            ruleId: "dep-advisory.vulnerable-pin",
            cwes: ["CWE-1395"],
            owaspMobile: "M2 Inadequate Supply Chain Security",
            owaspTop10: "A06:2021 Vulnerable and Outdated Components",
            description: "Pinned dependency version inside a range a published advisory says is affected",
            severity: "ERROR",
            lastReviewedDate: "2026-10-06",
            staleAfterDays: 180
        ),
        SecurityRule(
            ruleId: "dep-advisory.vulnerable-pin-by-name",
            cwes: ["CWE-1395"],
            owaspMobile: "M2 Inadequate Supply Chain Security",
            owaspTop10: "A06:2021 Vulnerable and Outdated Components",
            description: "Pinned dependency version affected by an advisory that names the package without a URL",
            severity: "ERROR",
            lastReviewedDate: "2026-10-06",
            staleAfterDays: 180
        ),
        // The randomness rules (ASeedIsNotASecret.md). Every CWE fetched from MITRE 4.20; 330 is
        // not used because MITRE marks it Discouraged. 335-338 and 340 are on A02:2021's mapped
        // list; 341 is not, and A02 is assigned to it by judgement, as the proposal says.
        SecurityRule(
            ruleId: "security.weak-prng",
            cwes: ["CWE-338"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Non-cryptographic generator (C rand family, GameplayKit) making a security value",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.seeded-secret",
            // Primary 335; the visitor cites 336 for a literal seed and 337 for a clock or pid seed.
            cwes: ["CWE-335", "CWE-336", "CWE-337"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Security value drawn from a generator seeded in the same function",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.predictable-token",
            cwes: ["CWE-341"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "Security value made only of the clock, the process id or a hash value",
            severity: "ERROR",
            lastReviewedDate: "2026-10-03"
        ),
        SecurityRule(
            ruleId: "security.uuid-as-secret",
            // 340 is a Class, kept after review: 341 is observable state and 342/343 prediction
            // from earlier values, and a v4 UUID is neither. A warning permanently.
            cwes: ["CWE-340"],
            owaspMobile: "M10 Insufficient Cryptography",
            owaspTop10: "A02:2021 Cryptographic Failures",
            description: "UUID used as a session id, token or key",
            severity: "WARNING",
            lastReviewedDate: "2026-10-03"
        ),
    ]

    /// The CWE recorded for a rule, or `nil` when the manifest does not list it.
    ///
    /// A diagnostic that cites a CWE in its message takes it from here rather than spelling
    /// it again, so the message, the manifest and the control mapping cannot name three
    /// different weaknesses for one rule.
    ///
    /// - Parameter ruleId: The rule identifier, e.g. `"security.weak-crypto"`.
    /// - Returns: The CWE identifier, e.g. `"CWE-328"`.
    public static func cwe(for ruleId: String) -> String? {
        rules.first { $0.ruleId == ruleId }?.cwe
    }

    /// Returns rules whose review date has exceeded their staleness threshold.
    ///
    /// - Parameter date: The reference date to check against (defaults to now).
    /// - Returns: Array of rules that are overdue for review.
    public static func staleRules(asOf date: Date = .now) -> [SecurityRule] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        return rules.filter { rule in
            guard let reviewDate = formatter.date(from: rule.lastReviewedDate) else {
                return true // Unparseable date counts as stale
            }
            let threshold = reviewDate.addingTimeInterval(
                Double(rule.staleAfterDays) * 86400
            )
            return date > threshold
        }
    }

    /// Exports all rules as Semgrep-compatible YAML.
    ///
    /// The output can be saved to a `.yaml` file and used with
    /// `semgrep --config rules.yaml` or `foxguard --rules rules.yaml`.
    ///
    /// - Returns: A string containing Semgrep YAML rule definitions.
    public static func semgrepYAML() -> String {
        var output = "rules:\n"

        for rule in rules {
            var metadata = [
                "cwe: [\(rule.cwes.joined(separator: ", "))]",
                "owasp-mobile: \"\(rule.owaspMobile)\"",
            ]
            if let top10 = rule.owaspTop10 { metadata.append("owasp-top10: \"\(top10)\"") }
            if let api = rule.owaspAPI { metadata.append("owasp-api: \"\(api)\"") }
            metadata.append("last-reviewed: \(rule.lastReviewedDate)")

            output += "  - id: \(rule.ruleId)\n"
            output += "    message: \"\(rule.description) [\(rule.cwes.joined(separator: ", "))]\"\n"
            output += "    severity: \(rule.severity)\n"
            output += "    languages: [swift]\n"
            output += "    metadata:\n"
            output += metadata.map { "      \($0)\n" }.joined()
            output += "    patterns:\n"
            output += "      - pattern: \"...\" # See SecurityVisitor for SwiftSyntax implementation\n\n"
        }

        return output
    }
}
