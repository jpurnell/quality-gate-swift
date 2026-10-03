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
            ruleId: "security.ssrf",
            cwes: ["CWE-918"],
            owaspMobile: "M5 Insecure Communication",
            owaspTop10: "A10:2021 Server-Side Request Forgery",
            description: "URL constructed from dynamic input",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
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
