import Foundation
#if canImport(os)
import os
#endif

/// Output format for the compliance coverage report.
public enum ComplianceReportFormat: String, Sendable, CaseIterable {
    case terminal
    case json
}

/// Renders the control-coverage matrix as the honest evidence artifact.
///
/// Every rendering leads with the disclaimer: this is technical-control coverage
/// by static analysis, **not** an assertion of compliance. Out-of-scope controls
/// are listed, never hidden.
public enum ComplianceReport {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "ComplianceReport")

    /// The scope-boundary statement printed with every report — the trust anchor
    /// and the liability shield.
    public static let disclaimer =
        "This report describes technical-control coverage by static analysis — it is NOT an assertion of compliance. "
        + "Out-of-scope controls require process/documentation evidence a static analyzer cannot see."

    /// Renders `matrix` in the requested format.
    public static func render(_ matrix: [ControlCoverage], format: ComplianceReportFormat) -> String {
        switch format {
        case .terminal: return terminal(matrix)
        case .json: return json(matrix)
        }
    }

    // MARK: - Terminal

    static func terminal(_ matrix: [ControlCoverage]) -> String {
        var lines: [String] = ["Control Coverage", disclaimer]

        var seenFrameworks: [String] = []
        for row in matrix where !seenFrameworks.contains(row.framework) {
            seenFrameworks.append(row.framework)
        }

        for framework in seenFrameworks {
            lines.append("")
            lines.append(framework)
            for row in matrix where row.framework == framework {
                var line = "  [\(row.state.rawValue)] \(row.controlId) — \(row.title)"
                if !row.rules.isEmpty {
                    line += "  ← \(row.rules.joined(separator: ", "))"
                }
                lines.append(line)
            }
        }

        let counts = summaryCounts(matrix)
        lines.append("")
        lines.append("Summary: \(counts["enforced"] ?? 0) enforced, "
            + "\(counts["evidence-only"] ?? 0) evidence-only, "
            + "\(counts["gap"] ?? 0) gap, "
            + "\(counts["out-of-scope"] ?? 0) out-of-scope")
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON

    private struct JSONReport: Codable {
        let disclaimer: String
        let summary: [String: Int]
        let controls: [ControlCoverage]
    }

    static func json(_ matrix: [ControlCoverage]) -> String {
        let report = JSONReport(
            disclaimer: disclaimer,
            summary: summaryCounts(matrix),
            controls: matrix)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // "{}" is a valid document and a useless report — a consumer cannot tell it from
        // a genuinely empty result. Encoding a plain value type should not fail, so if it
        // ever does that is the interesting fact, not the fallback.
        let data: Data
        do {
            data = try encoder.encode(report)
        } catch {
            Self.logger.warning(
                "control-mapping could not encode its compliance report; emitting an empty document: \(error.localizedDescription, privacy: .public)")
            return "{}"
        }
        guard let string = String(data: data, encoding: .utf8) else {
            Self.logger.warning("control-mapping encoded a compliance report that is not valid UTF-8; emitting an empty document")
            return "{}"
        }
        return string
    }

    /// Count of controls in each coverage state, keyed by the state's raw value.
    private static func summaryCounts(_ matrix: [ControlCoverage]) -> [String: Int] {
        Dictionary(grouping: matrix, by: { $0.state.rawValue }).mapValues(\.count)
    }
}
