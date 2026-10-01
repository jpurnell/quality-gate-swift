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
            description: "TLS certificate validation disabled or weakened",
            severity: "ERROR",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.path-traversal",
            cwes: ["CWE-22"],
            owaspMobile: "M4 Insufficient Input/Output Validation",
            owaspTop10: "A01:2021 Broken Access Control",
            description: "FileManager operation with dynamic unsanitized path",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
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
