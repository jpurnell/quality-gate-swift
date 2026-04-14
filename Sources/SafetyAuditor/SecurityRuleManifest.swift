import Foundation

/// Metadata for a single security scanning rule.
///
/// Each rule maps to a CWE identifier and an OWASP Mobile Top 10 (2024) category.
/// The `lastReviewedDate` field is used by CI staleness checks to ensure rules
/// are periodically reviewed against current Apple SDK APIs.
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

    /// CWE identifier (e.g. "CWE-798").
    public let cwe: String

    /// OWASP Mobile Top 10 (2024) category (e.g. "M1 Improper Credential Usage").
    public let owaspCategory: String

    /// Human-readable description of what the rule detects.
    public let description: String

    /// ISO 8601 date when the rule was last reviewed (YYYY-MM-DD).
    public let lastReviewedDate: String

    /// Number of days after `lastReviewedDate` before the rule is considered stale.
    public let staleAfterDays: Int

    /// Semgrep-compatible severity level.
    public let severity: String

    /// Creates a new security rule definition.
    public init(
        ruleId: String,
        cwe: String,
        owaspCategory: String,
        description: String,
        severity: String,
        lastReviewedDate: String,
        staleAfterDays: Int = 365
    ) {
        self.ruleId = ruleId
        self.cwe = cwe
        self.owaspCategory = owaspCategory
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
            cwe: "CWE-798",
            owaspCategory: "M1 Improper Credential Usage",
            description: "Variable named like a secret assigned a string literal",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.command-injection",
            cwe: "CWE-78",
            owaspCategory: "M4 Insufficient I/O Validation",
            description: "Process/NSTask with dynamic launch path or arguments",
            severity: "ERROR",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.weak-crypto",
            cwe: "CWE-327",
            owaspCategory: "M10 Insufficient Cryptography",
            description: "Use of weak cryptographic hash (MD5/SHA1)",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.insecure-transport",
            cwe: "CWE-319",
            owaspCategory: "M5 Insecure Communication",
            description: "Insecure HTTP URL detected (use HTTPS)",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.eval-js",
            cwe: "CWE-95",
            owaspCategory: "M4 Insufficient I/O Validation",
            description: "WKWebView evaluateJavaScript with dynamic input",
            severity: "ERROR",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.sql-injection",
            cwe: "CWE-89",
            owaspCategory: "M4 Insufficient I/O Validation",
            description: "String interpolation passed to SQL-executing function",
            severity: "ERROR",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.insecure-keychain",
            cwe: "CWE-311",
            owaspCategory: "M9 Insecure Data Storage",
            description: "Deprecated insecure Keychain accessibility level",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.tls-disabled",
            cwe: "CWE-295",
            owaspCategory: "M5 Insecure Communication",
            description: "TLS certificate validation disabled or weakened",
            severity: "ERROR",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.path-traversal",
            cwe: "CWE-22",
            owaspCategory: "M4 Insufficient I/O Validation",
            description: "FileManager operation with dynamic unsanitized path",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
        ),
        SecurityRule(
            ruleId: "security.ssrf",
            cwe: "CWE-918",
            owaspCategory: "M5 Insecure Communication",
            description: "URL constructed from dynamic input",
            severity: "WARNING",
            lastReviewedDate: "2026-04-14"
        ),
    ]

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
            output += """
              - id: \(rule.ruleId)
                message: "\(rule.description) [\(rule.cwe)]"
                severity: \(rule.severity)
                languages: [swift]
                metadata:
                  cwe: \(rule.cwe)
                  owasp: "\(rule.owaspCategory)"
                  last-reviewed: \(rule.lastReviewedDate)
                patterns:
                  - pattern: "..." # See SecurityVisitor for SwiftSyntax implementation

            """
        }

        return output
    }
}
