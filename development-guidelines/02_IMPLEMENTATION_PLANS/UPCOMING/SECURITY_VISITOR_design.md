# Design Proposal: SecurityVisitor for SafetyAuditor

## 1. Objective

Add OWASP Mobile Top 10 security vulnerability detection to the existing SafetyAuditor module via a new `SecurityVisitor` — a SwiftSyntax-based visitor that catches common security anti-patterns in Swift source code at compile time.

**Master Plan Reference:** Phase 2 — Checker Modules (extends existing `SafetyAuditor` rather than creating a new module)

**Motivation:** A Foxguard (tree-sitter SAST) audit of the BusinessMath project returned 4 findings — 1 real path-traversal issue and 3 false positives where `fatalError` messages were flagged as SQL injection. SwiftSyntax gives us full AST context to avoid these false positives while covering the same OWASP-mapped vulnerability classes.

**Target patterns (10 rules mapped to OWASP Mobile 2024):**

| Rule ID | CWE | OWASP 2024 | Pattern |
|---------|-----|------------|---------|
| `security.hardcoded-secret` | 798 | M1 Improper Credential Usage | Variable named `password`/`secret`/`apiKey`/`token`/`credential` assigned a string literal |
| `security.command-injection` | 78 | M4 Insufficient I/O Validation | `Process`/`NSTask` instantiation with dynamic `launchPath`/`arguments` |
| `security.weak-crypto` | 327 | M10 Insufficient Cryptography | Calls to `CC_MD5`, `CC_SHA1`, `Insecure.MD5`, `Insecure.SHA1` |
| `security.insecure-transport` | 319 | M5 Insecure Communication | `http://` string literals (excluding `localhost`/`127.0.0.1`) |
| `security.eval-js` | 95 | M4 Insufficient I/O Validation | `evaluateJavaScript` called with interpolated or variable argument |
| `security.sql-injection` | 89 | M4 Insufficient I/O Validation | String interpolation inside a string passed to a known SQL-executing function (NOT in `fatalError`, `print`, `precondition`, or doc comments) |
| `security.insecure-keychain` | 311 | M9 Insecure Data Storage | Deprecated `kSecAttrAccessibleAlways`, `kSecAttrAccessibleAlwaysThisDeviceOnly` |
| `security.tls-disabled` | 295 | M5 Insecure Communication | `.allowsExpiredCertificates = true`, `.allowsExpiredRoots = true`, `.disableEvaluation()` on `SecTrust`/`ServerTrust` |
| `security.path-traversal` | 22 | M4 Insufficient I/O Validation | `FileManager` operations with non-literal, non-standardized path arguments |
| `security.ssrf` | 918 | M5 Insecure Communication | `URL(string:)` or `URLSession.dataTask` with interpolated/variable URL argument |

## 2. Proposed Architecture

**No new module.** SecurityVisitor lives inside the existing SafetyAuditor module alongside SafetyVisitor.

**New files:**
- `Sources/SafetyAuditor/SecurityVisitor.swift` — `SyntaxVisitor` subclass with 10 security rules
- `Sources/SafetyAuditor/SecurityRuleManifest.swift` — Rule metadata registry (rule ID, CWE, OWASP mapping, date last reviewed)
- `Tests/SafetyAuditorTests/SecurityVisitorTests.swift` — Red/green fixture pairs for all 10 rules

**Modified files:**
- `Sources/SafetyAuditor/SafetyAuditor.swift` — wire SecurityVisitor into `auditSourceCode`, merge its diagnostics with SafetyVisitor's
- `Sources/QualityGateCore/Configuration.swift` — add `security: SecurityAuditorConfig` block with `enabledRules`, `secretPatterns`, `allowedHTTPHosts`, `exemptionPattern`
- `.quality-gate.yml` — document new config keys

**New workflow:**
- `.github/workflows/security-rule-staleness.yml` — bi-monthly cron to check rule review dates

### Module Placement

SecurityVisitor is deliberately NOT a separate module. It shares SafetyAuditor's exemption infrastructure, file enumeration, and `QualityChecker` entry point. Users run `--check safety` and get both code-safety and security diagnostics in one pass. The `enabledRules` config allows disabling individual security rules without disabling the full safety checker.

## 3. API Surface

```swift
// SecurityVisitor.swift — private to SafetyAuditor module
final class SecurityVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    let sourceLines: [String]
    let exemptionPatterns: [String]
    let configuration: SecurityAuditorConfig
    private(set) var diagnostics: [Diagnostic] = []

    init(fileName: String, source: String,
         exemptionPatterns: [String],
         configuration: SecurityAuditorConfig)

    // Visitor methods
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind
    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind
}

// SecurityRuleManifest.swift — public for CI staleness checks
public struct SecurityRule: Sendable, Codable {
    public let ruleId: String
    public let cwe: String
    public let owaspCategory: String
    public let description: String
    public let lastReviewedDate: String     // ISO 8601 (YYYY-MM-DD)
    public let staleAfterDays: Int          // default 365
}

public enum SecurityRuleManifest {
    /// All registered security rules with their metadata.
    public static let rules: [SecurityRule]

    /// Rules whose lastReviewedDate + staleAfterDays < today.
    public static func staleRules(asOf date: Date = .now) -> [SecurityRule]
}
```

```swift
// Configuration addition
public struct SecurityAuditorConfig: Sendable, Codable, Equatable {
    /// Which security rules to enable (empty = all enabled)
    public var enabledRules: [String]

    /// Regex patterns for variable names that indicate secrets.
    /// Default: ["password", "secret", "apiKey", "api_key", "token",
    ///           "credential", "privateKey", "private_key"]
    public var secretPatterns: [String]

    /// Hosts allowed to use http:// (e.g. localhost test servers).
    /// Default: ["localhost", "127.0.0.1", "0.0.0.0"]
    public var allowedHTTPHosts: [String]

    /// SQL-executing function names that trigger sql-injection checks.
    /// Default: ["execute", "prepare", "query", "rawQuery",
    ///           "sqlite3_exec", "sqlite3_prepare"]
    public var sqlFunctionNames: [String]

    public static let `default`: SecurityAuditorConfig
}
```

## 4. MCP Schema

**N/A.** This extends the existing `safety` checker invoked via CLI/SPM plugin. The umbrella `quality-gate` MCP description lists `safety` as a checker; no additional schema needed. Security diagnostics appear in the same `CheckResult` as existing safety diagnostics.

## 5. Constraints & Compliance

- **Concurrency:** `SecurityVisitor` is a reference type (SyntaxVisitor requirement) but confined to a single `check` invocation — never shared across threads.
- **Safety:** No force unwraps. Guard clauses for all AST node pattern-matching.
- **No false positives over false negatives:** The key differentiator vs. tree-sitter tools. Every rule must prove it's in an executable code context, not a comment or error message. The `sql-injection` rule specifically excludes `fatalError`, `precondition`, `assertionFailure`, `print`, `debugPrint`, and doc comment contexts.
- **Exemption system:** Reuses the existing `// SAFETY:` exemption pattern from SafetyAuditor. A `// SECURITY:` alias is added to the default exemption list.
- **Plugin parity:** Same `Diagnostic` model, same reporters, same SARIF output as all other checkers.

## 6. Backend Abstraction

**N/A** — pure SwiftSyntax AST walking. CPU-only.

## 7. Dependencies

**Internal:**
- `QualityGateCore` (protocol, models, Configuration)
- `SwiftSyntax`, `SwiftParser` (already used by SafetyAuditor)

**External:** None new.

## 8. Test Strategy

**Test categories (per rule):**

Each rule gets a positive fixture (must flag) and a negative fixture (must NOT flag):

| Rule | Positive fixture (must flag) | Negative fixture (must NOT flag) |
|------|------------------------------|----------------------------------|
| `hardcoded-secret` | `let apiKey = "sk-abc123"` | `let apiKey = ProcessInfo.processInfo.environment["API_KEY"]` |
| `command-injection` | `Process().launchPath = userInput` | `Process().launchPath = "/usr/bin/git"` (string literal) |
| `weak-crypto` | `CC_MD5(data, len, &digest)` | `SHA256.hash(data: input)` |
| `insecure-transport` | `URL(string: "http://api.example.com")` | `URL(string: "http://localhost:8080")` |
| `eval-js` | `webView.evaluateJavaScript(userScript)` | `webView.evaluateJavaScript("document.title")` (literal) |
| `sql-injection` | `db.execute("SELECT * FROM users WHERE id = \(userId)")` | `fatalError("Failed query \(error)")` |
| `insecure-keychain` | `kSecAttrAccessibleAlways` | `kSecAttrAccessibleWhenUnlocked` |
| `tls-disabled` | `trust.allowsExpiredCertificates = true` | `trust.allowsExpiredCertificates = false` |
| `path-traversal` | `FileManager.default.fileExists(atPath: userPath)` | `FileManager.default.fileExists(atPath: "/known/path")` (literal) |
| `ssrf` | `URL(string: "\(baseURL)/api")` | `URL(string: "https://api.example.com")` (literal) |

**Additional test categories:**
- **Exemptions:** `// SAFETY:` and `// SECURITY:` comments suppress diagnostics
- **Doc comment immunity:** Interpolation inside `///` comments must NOT trigger any rule
- **Configuration:** `enabledRules: ["hardcoded-secret"]` disables all other rules
- **Multiple violations:** File with 5+ security issues reports all of them
- **Diagnostic quality:** Each diagnostic includes `ruleId`, `suggestedFix`, CWE in message

**Reference truth:** Hand-authored Swift fixtures. No external validation source needed — these are pattern-matching rules, not numerical computations.

## 9. Open Questions

- Should `security.ssrf` flag ALL non-literal `URL(string:)` calls, or only those passed to `URLSession`? **Proposed:** flag all — the URL construction itself is the risk point.
- Should `security.sql-injection` support a configurable list of "safe" wrapper functions (e.g., parameterized query builders)? **Proposed:** yes, via `sqlFunctionNames` config — if the function isn't in the list, the rule doesn't fire.
- Should the `// SECURITY:` exemption be a separate config key or share `safetyExemptions`? **Proposed:** share — keeps one exemption system. Add `"// SECURITY:"` to the default list.

## 10. Documentation Strategy

**Documentation Type:** API Docs Only (extend SafetyAuditor's DocC catalog).

- 3+ APIs combined? No (internal visitor, public manifest only).
- 50+ line explanation? No.
- Theory/background? No.

Add a `SecurityRules.md` article to the SafetyAuditor DocC catalog listing each rule, its CWE/OWASP mapping, positive/negative examples, and how to configure or exempt. This doubles as the staleness review reference.

---

## OWASP Coverage Matrix

This matrix is the source of truth for rule coverage. Review annually against the latest OWASP Mobile Top 10.

| OWASP 2024 | Statically detectable? | Rules | Coverage |
|------------|----------------------|-------|----------|
| M1 Improper Credential Usage | Yes | `hardcoded-secret` | Partial — catches hardcoded, not mismanaged |
| M2 Supply Chain Security | No | — | Out of scope (dependency auditing) |
| M3 Insecure Auth/AuthZ | Partially | `tls-disabled` | Partial — auth logic needs runtime testing |
| M4 Insufficient I/O Validation | Yes | `command-injection`, `sql-injection`, `eval-js`, `path-traversal` | Strong |
| M5 Insecure Communication | Yes | `insecure-transport`, `ssrf`, `tls-disabled` | Strong |
| M6 Inadequate Privacy | Partially | `insecure-keychain` | Partial — data-at-rest only |
| M7 Binary Protections | No | — | Out of scope (build/deploy concern) |
| M8 Security Misconfiguration | Partially | `tls-disabled` | Partial |
| M9 Insecure Data Storage | Yes | `insecure-keychain` | Partial |
| M10 Insufficient Cryptography | Yes | `weak-crypto` | Strong for known-bad algorithms |

---

## Staleness Model

Each rule in `SecurityRuleManifest.rules` carries a `lastReviewedDate` and `staleAfterDays` (default: 365). A CI workflow runs bi-monthly and opens an issue if any rule is stale.

**Review triggers (outside the scheduled check):**
- **WWDC (June annually):** Review all rules against new/deprecated Apple APIs
- **OWASP Mobile Top 10 refresh (every 2-3 years):** Re-run the coverage matrix
- **New project type adopted:** If a project starts using a new framework (e.g., Vapor for server-side), assess whether new rules are needed

---

## Future Work (out of scope for v1)

- Taint tracking across function boundaries (source → sink analysis)
- Cross-file dataflow for SSRF and injection patterns
- `Info.plist` analysis (ATS exceptions, permission usage descriptions)
- Dependency vulnerability scanning (supply chain — OWASP M2)
- Runtime-only patterns (auth bypass, improper session handling)
- Auto-fix suggestions via SwiftSyntax rewriting
