import Foundation
import QualityGateCore

/// Per-module orientation facts consumed by the central-unoriented rule.
struct ModuleOrientation: Sendable, Equatable {
    /// The module's name.
    let moduleName: String
    /// Whether the module has a conceptual overview (DocC catalog landing page).
    let hasOrientationDoc: Bool

    /// Creates a module-orientation fact.
    init(moduleName: String, hasOrientationDoc: Bool) {
        self.moduleName = moduleName
        self.hasOrientationDoc = hasOrientationDoc
    }
}

/// A live-but-over-exposed public symbol, joined from the surface and semantic
/// passes and annotated with any acknowledgment.
struct OverPublicOccurrence: Sendable, Equatable {
    /// The symbol's declared name.
    let symbolName: String
    /// The module that defines it.
    let moduleName: String
    /// Absolute path to the defining file.
    let filePath: String
    /// 1-based declaration line.
    let line: Int
    /// Whether the exposure is acknowledged (reserved marker or config exemption).
    let acknowledged: Bool
    /// The acknowledgment text, recorded on the compliance record when acknowledged.
    let acknowledgment: String?

    /// Creates an over-public occurrence.
    init(
        symbolName: String,
        moduleName: String,
        filePath: String,
        line: Int,
        acknowledged: Bool,
        acknowledgment: String? = nil
    ) {
        self.symbolName = symbolName
        self.moduleName = moduleName
        self.filePath = filePath
        self.line = line
        self.acknowledged = acknowledged
        self.acknowledgment = acknowledgment
    }
}

/// The advisory output of the legibility rules: notes plus recorded
/// acknowledgments. Never contains an `.error` or `.warning` — the analyzer is
/// advisory-only and never gates.
struct LegibilityFindings: Sendable, Equatable {
    /// Advisory `.note` diagnostics.
    var diagnostics: [Diagnostic]
    /// Acknowledged exceptions, surfaced (not dropped) as compliance records.
    var compliance: [ComplianceRecord]

    /// Creates a findings bundle.
    init(diagnostics: [Diagnostic] = [], compliance: [ComplianceRecord] = []) {
        self.diagnostics = diagnostics
        self.compliance = compliance
    }
}

/// The three legibility rules, as pure functions over already-resolved facts.
///
/// Each emits only `Severity.note`. All ranking and iteration is deterministic
/// (stable sorts, name tie-breaks) so output is reproducible across runs.
enum LegibilityRules {

    static let centralUnorientedRuleID = "legibility.central-unoriented"
    static let moduleCycleRuleID = "legibility.module-cycle"
    static let overPublicRuleID = "legibility.over-public-symbol"

    /// Rule 1 — a load-bearing module (high fan-in) lacking a conceptual overview.
    ///
    /// Flags the top *N* central-but-unoriented modules, ranked by weighted
    /// fan-in. Modules without a known orientation fact, exempt modules, and any
    /// module with an overview are not flagged.
    static func centralUnoriented(
        graph: ModuleGraph,
        orientation: [ModuleOrientation],
        config: LegibilityAnalyzerConfig
    ) -> [Diagnostic] {
        let unorientedModules = Set(
            orientation.filter { !$0.hasOrientationDoc }.map(\.moduleName)
        )

        let candidates = graph.modules
            .filter { !config.exemptModules.contains($0) }
            .filter { unorientedModules.contains($0) }
            .filter { graph.fanIn($0) >= config.minFanInForCentral }
            .sorted { lhs, rhs in
                let lhsRank = graph.weightedFanIn(lhs)
                let rhsRank = graph.weightedFanIn(rhs)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                return lhs < rhs
            }
            .prefix(config.centralUnorientedTopN)

        return candidates.map { module in
            let fanIn = graph.fanIn(module)
            return Diagnostic(
                severity: .note,
                message: "\(module) is referenced by \(fanIn) module\(fanIn == 1 ? "" : "s") but has no module-level orientation doc. A newcomer must reconstruct its purpose from call sites.",
                ruleId: centralUnorientedRuleID,
                suggestedFix: "Add a DocC catalog overview describing \(module)'s purpose, its entry point, and how its pieces fit together."
            )
        }
    }

    /// Rule 2 — a dependency cycle, for which no clean reading order exists.
    static func moduleCycles(
        graph: ModuleGraph,
        config: LegibilityAnalyzerConfig
    ) -> [Diagnostic] {
        guard config.flagCycles else { return [] }
        return graph.cycles().map { cycle in
            let members = cycle.sorted().joined(separator: " → ")
            let count = cycle.count
            return Diagnostic(
                severity: .note,
                message: "Dependency cycle among \(count) modules: \(members). No clean reading order exists through them.",
                ruleId: moduleCycleRuleID,
                suggestedFix: "Break the cycle by extracting the shared type into a lower layer, or invert one edge with a protocol."
            )
        }
    }

    /// Rule 3 — a `public` symbol referenced only within its own module.
    ///
    /// Unacknowledged occurrences become `.note` diagnostics with a fix; the
    /// acknowledged ones become compliance records (surfaced, not dropped).
    static func overPublicSymbols(
        _ occurrences: [OverPublicOccurrence],
        config: LegibilityAnalyzerConfig
    ) -> LegibilityFindings {
        guard config.flagOverPublicSymbols else { return LegibilityFindings() }

        let ordered = occurrences.sorted { lhs, rhs in
            if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
            if lhs.line != rhs.line { return lhs.line < rhs.line }
            return lhs.symbolName < rhs.symbolName
        }

        var findings = LegibilityFindings()
        for occ in ordered {
            if occ.acknowledged {
                findings.compliance.append(
                    ComplianceRecord(
                        ruleId: overPublicRuleID,
                        annotation: occ.acknowledgment ?? "acknowledged reserved public surface",
                        filePath: occ.filePath,
                        lineNumber: occ.line
                    )
                )
            } else {
                findings.diagnostics.append(
                    Diagnostic(
                        severity: .note,
                        message: "\(occ.symbolName) is public but referenced only within \(occ.moduleName) — its public visibility overstates the module's contract.",
                        filePath: occ.filePath,
                        lineNumber: occ.line,
                        ruleId: overPublicRuleID,
                        suggestedFix: "Mark \(occ.symbolName) internal, or acknowledge intentional exposure with `// legibility:reserved <reason>`."
                    )
                )
            }
        }
        return findings
    }
}
