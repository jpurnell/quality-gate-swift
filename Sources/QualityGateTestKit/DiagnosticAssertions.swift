import Testing
import QualityGateCore

/// Assert a specific rule was triggered in the check result.
///
/// Searches the result's diagnostics for one matching the given `ruleId`.
/// Optionally filters by severity, line number, or message substring.
///
/// - Parameters:
///   - result: The check result to inspect.
///   - ruleId: The rule identifier to look for.
///   - severity: If provided, the matching diagnostic must have this severity.
///   - line: If provided, the matching diagnostic must be at this line number.
///   - substring: If provided, the matching diagnostic's message must contain this.
///   - sourceLocation: Caller source location for failure reporting.
public func expectDiagnostic(
    in result: CheckResult,
    ruleId: String,
    severity: Diagnostic.Severity? = nil,
    atLine line: Int? = nil,
    messageContaining substring: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var candidates = result.diagnostics.filter { $0.ruleId == ruleId }

    if candidates.isEmpty {
        let allRuleIds = result.diagnostics.compactMap(\.ruleId)
        Issue.record(
            "Expected diagnostic with ruleId \"\(ruleId)\" but none found. Available ruleIds: \(allRuleIds)",
            sourceLocation: sourceLocation
        )
        return
    }

    if let severity {
        candidates = candidates.filter { $0.severity == severity }
        if candidates.isEmpty {
            Issue.record(
                "Found diagnostic with ruleId \"\(ruleId)\" but none with severity \(severity)",
                sourceLocation: sourceLocation
            )
            return
        }
    }

    if let line {
        candidates = candidates.filter { $0.lineNumber == line }
        if candidates.isEmpty {
            let foundLines = result.diagnostics
                .filter { $0.ruleId == ruleId }
                .compactMap(\.lineNumber)
            Issue.record(
                "Found diagnostic with ruleId \"\(ruleId)\" but none at line \(line). Found at lines: \(foundLines)",
                sourceLocation: sourceLocation
            )
            return
        }
    }

    if let substring {
        candidates = candidates.filter { $0.message.contains(substring) }
        if candidates.isEmpty {
            let messages = result.diagnostics
                .filter { $0.ruleId == ruleId }
                .map(\.message)
            Issue.record(
                "Found diagnostic with ruleId \"\(ruleId)\" but none containing \"\(substring)\". Messages: \(messages)",
                sourceLocation: sourceLocation
            )
            return
        }
    }

    // At least one diagnostic matched all criteria -- success.
}

/// Assert a specific rule was NOT triggered.
///
/// Fails if any diagnostic in the result has the given `ruleId`.
///
/// - Parameters:
///   - result: The check result to inspect.
///   - ruleId: The rule identifier that should be absent.
///   - sourceLocation: Caller source location for failure reporting.
public func expectNoDiagnostic(
    in result: CheckResult,
    ruleId: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let matches = result.diagnostics.filter { $0.ruleId == ruleId }
    if !matches.isEmpty {
        Issue.record(
            "Expected no diagnostic with ruleId \"\(ruleId)\" but found \(matches.count): \(matches.map(\.message))",
            sourceLocation: sourceLocation
        )
    }
}

/// Assert no diagnostics were emitted (clean pass).
///
/// Fails if the result contains any diagnostics at all.
///
/// - Parameters:
///   - result: The check result to inspect.
///   - sourceLocation: Caller source location for failure reporting.
public func expectClean(
    _ result: CheckResult,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if !result.diagnostics.isEmpty {
        let summary = result.diagnostics.map { diag in
            "\(diag.severity): \(diag.message) [\(diag.ruleId ?? "no-rule")]"
        }
        Issue.record(
            "Expected clean result but found \(result.diagnostics.count) diagnostic(s): \(summary)",
            sourceLocation: sourceLocation
        )
    }
}

/// Assert the result has a specific status.
///
/// - Parameters:
///   - result: The check result to inspect.
///   - status: The expected status value.
///   - sourceLocation: Caller source location for failure reporting.
public func expectStatus(
    _ result: CheckResult,
    _ status: CheckResult.Status,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        result.status == status,
        "Expected status \(status) but got \(result.status)",
        sourceLocation: sourceLocation
    )
}

/// Assert the result contains exactly N diagnostics with the given rule ID.
///
/// - Parameters:
///   - result: The check result to inspect.
///   - ruleId: The rule identifier to count.
///   - count: The expected number of matches.
///   - sourceLocation: Caller source location for failure reporting.
public func expectDiagnosticCount(
    in result: CheckResult,
    ruleId: String,
    count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let actual = result.diagnostics.filter { $0.ruleId == ruleId }.count
    #expect(
        actual == count,
        "Expected \(count) diagnostic(s) with ruleId \"\(ruleId)\" but found \(actual)",
        sourceLocation: sourceLocation
    )
}
