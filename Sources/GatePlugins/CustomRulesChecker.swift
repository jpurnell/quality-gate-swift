import Foundation
import QualityGateCore

/// Tier-1 declarative custom rules (Phase 4b): SwiftLint `custom_rules`
/// parity — line regexes declared in `.quality-gate.yml`, no code required.
///
/// Custom rules are first-class citizens: they report under their own `id`,
/// carry `origin: custom-rule` into telemetry, respect the `// custom:exempt`
/// escape hatch (recorded, never silent), and may gate — they are the user's
/// own policy, so gating is theirs to declare via each rule's `severity`.
public struct CustomRulesChecker: QualityChecker, Sendable {
    /// Checker identifier.
    public let id = "custom-rules"
    /// Display name.
    public let name = "Custom Rules"

    /// Package root to scan; nil means the current working directory.
    let root: String?

    /// Wall time above which a rule's cost surfaces as a note — a
    /// pathological regex should be a visible cost, not a mystery.
    let slowRuleThreshold: Duration

    /// Creates the checker.
    ///
    /// - Parameters:
    ///   - root: Package root to scan (defaults to the working directory).
    ///   - slowRuleThreshold: Per-rule visibility threshold, one second by
    ///     default (injectable for tests).
    public init(root: String? = nil, slowRuleThreshold: Duration = .seconds(1)) {
        self.root = root
        self.slowRuleThreshold = slowRuleThreshold
    }

    /// Runs every configured rule over the project's Swift sources.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let rules = configuration.customRules
        guard !rules.isEmpty else {
            return CheckResult(
                checkerId: id, status: .skipped,
                diagnostics: [], duration: ContinuousClock.now - startTime)
        }

        let scanRoot = root ?? FileManager.default.currentDirectoryPath
        let files = Self.swiftFiles(under: scanRoot)

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        for rule in rules {
            let ruleStart = ContinuousClock.now
            let findings = Self.apply(rule: rule, to: files, root: scanRoot)
            diagnostics.append(contentsOf: findings.diagnostics)
            overrides.append(contentsOf: findings.overrides)
            let elapsed = ContinuousClock.now - ruleStart
            if elapsed > slowRuleThreshold {
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "custom rule '\(rule.id)' took \(elapsed) — check the pattern for catastrophic backtracking or over-broad scope",
                    ruleId: "custom-rules.slow-rule",
                    origin: "custom-rule"))
            }
        }

        let status: CheckResult.Status =
            if diagnostics.contains(where: { $0.severity == .error }) {
                .failed
            } else if diagnostics.contains(where: { $0.severity == .warning }) {
                .warning
            } else {
                .passed
            }
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            overrides: overrides,
            duration: ContinuousClock.now - startTime)
    }

    // MARK: - Engine (pure over its inputs; internal for tests)

    /// One rule's findings over a file set.
    ///
    /// An unparsable pattern is itself an error finding under the rule's id —
    /// policy that cannot execute must be loud, whatever severity it declared.
    static func apply(
        rule: CustomRuleConfig,
        to files: [String],
        root: String
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        // silent: an unparsable pattern becomes the error finding just below
        guard let regex = try? NSRegularExpression(pattern: rule.pattern) else {
            return ([Diagnostic(
                severity: .error,
                message: "custom rule '\(rule.id)' has an invalid pattern: \(rule.pattern)",
                ruleId: rule.id,
                origin: "custom-rule")], [])
        }

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        for file in files {
            let relative = String(file.dropFirst(root.count).drop(while: { $0 == "/" }))
            guard Self.included(relative, rule: rule) else { continue }
            // silent: an unreadable file is simply not scanned by a line-regex rule
            guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard regex.firstMatch(in: line, options: [], range: range) != nil else { continue }
                if line.contains("// custom:exempt") {
                    overrides.append(DiagnosticOverride(
                        ruleId: rule.id,
                        justification: "// custom:exempt",
                        filePath: file,
                        lineNumber: index + 1))
                    continue
                }
                diagnostics.append(Diagnostic(
                    severity: rule.severity,
                    message: rule.message,
                    filePath: file,
                    lineNumber: index + 1,
                    ruleId: rule.id,
                    origin: "custom-rule"))
            }
        }
        return (diagnostics, overrides)
    }

    /// Include/exclude filtering with shell-style globs (`fnmatch`); a
    /// pattern with no wildcard matches as a path prefix or substring.
    /// Exclude wins over include; an empty include list means everything.
    static func included(_ relativePath: String, rule: CustomRuleConfig) -> Bool {
        func matches(_ pattern: String) -> Bool {
            if pattern.contains("*") || pattern.contains("?") {
                return fnmatch(pattern, relativePath, 0) == 0
            }
            return relativePath.hasPrefix(pattern) || relativePath.contains(pattern)
        }
        if rule.exclude.contains(where: matches) { return false }
        guard !rule.include.isEmpty else { return true }
        return rule.include.contains(where: matches)
    }

    /// Every `.swift` file under `Sources/` and `Tests/`, sorted for
    /// deterministic finding order.
    static func swiftFiles(under root: String) -> [String] {
        var files: [String] = []
        for dir in ["Sources", "Tests"] {
            let base = (root as NSString).appendingPathComponent(dir)
            guard let enumerator = FileManager.default.enumerator(atPath: base) else { continue }
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".swift") else { continue }
                files.append((base as NSString).appendingPathComponent(relative))
            }
        }
        return files.sorted()
    }
}
