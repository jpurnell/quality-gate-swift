import Foundation
import QualityGateCore

/// Cross-file documentation analysis backed by IndexStoreDB (Pass 2).
///
/// Adds two capabilities on top of the syntactic Pass 1:
///
/// 1. **Inherited documentation detection** — Protocol extension default
///    implementations whose protocol requirement has a doc comment are
///    reclassified as "documented via inheritance" via `doc-inherited` info
///    diagnostics. The Pass 1 `missing-doc` warning is preserved for
///    backward compatibility, but effective coverage is adjusted upward.
///
/// 2. **Usage-priority ranking** — Undocumented APIs (not resolved by
///    inheritance) are ranked by IndexStoreDB reference count. The top N
///    emit `doc-usage-priority` info diagnostics suggesting which APIs to
///    document first.
///
/// The analysis logic is split into pure static functions
/// (``classifyInheritedDocs(undocumentedAPIs:protocolRequirementDocs:)``,
/// ``rankByUsage(undocumentedAPIs:referenceCounts:topN:)``,
/// ``adjustedSummary(totalAPIs:explicitlyDocumented:inheritedCount:threshold:)``)
/// so that unit tests can exercise them without a live IndexStoreDB session.
///
/// ## Graceful degradation
/// When the index store is unavailable, the pass emits a single `.note`
/// diagnostic and returns — it never fails the quality gate.
public enum DocCoverageIndexPass: Sendable {

    // MARK: - Data types

    /// Describes an undocumented public API discovered by Pass 1.
    public struct UndocumentedAPI: Sendable, Equatable {
        /// The name of the undocumented API (e.g. "doSomething").
        public let name: String
        /// The kind of API (e.g. "function", "struct", "property").
        public let apiType: String
        /// Absolute path to the file containing the declaration.
        public let filePath: String
        /// 1-based line number of the declaration.
        public let line: Int
        /// Unified Symbol Resolution identifier, if available from the index.
        public let usr: String?

        /// Creates an undocumented API descriptor.
        ///
        /// - Parameters:
        ///   - name: The API name.
        ///   - apiType: The kind of declaration.
        ///   - filePath: Absolute path to the source file.
        ///   - line: 1-based line number.
        ///   - usr: Optional USR for index-backed lookups.
        public init(name: String, apiType: String, filePath: String, line: Int, usr: String? = nil) {
            self.name = name
            self.apiType = apiType
            self.filePath = filePath
            self.line = line
            self.usr = usr
        }
    }

    /// Aggregated inputs from Pass 1 needed by Pass 2.
    public struct Inputs: Sendable {
        /// All Pass 1 diagnostics (preserved for merging).
        public let pass1Diagnostics: [Diagnostic]
        /// Total number of public APIs detected by Pass 1.
        public let totalPublicAPIs: Int
        /// Number of APIs with explicit documentation comments.
        public let documentedAPIs: Int
        /// Documentation coverage threshold from configuration (nil = strict mode).
        public let threshold: Int?

        /// Creates a Pass 2 inputs bundle.
        ///
        /// - Parameters:
        ///   - pass1Diagnostics: Diagnostics produced by Pass 1.
        ///   - totalPublicAPIs: Total public API count.
        ///   - documentedAPIs: Explicitly documented API count.
        ///   - threshold: Coverage threshold percentage, if configured.
        public init(
            pass1Diagnostics: [Diagnostic],
            totalPublicAPIs: Int,
            documentedAPIs: Int,
            threshold: Int?
        ) {
            self.pass1Diagnostics = pass1Diagnostics
            self.totalPublicAPIs = totalPublicAPIs
            self.documentedAPIs = documentedAPIs
            self.threshold = threshold
        }
    }

    /// Results produced by Pass 2.
    public struct Results: Sendable {
        /// The original Pass 1 diagnostics (unchanged).
        public let pass1Diagnostics: [Diagnostic]
        /// `doc-inherited` info diagnostics for APIs documented via protocol inheritance.
        public let inheritedDiagnostics: [Diagnostic]
        /// `doc-usage-priority` info diagnostics ranking undocumented APIs by reference count.
        public let usagePriorityDiagnostics: [Diagnostic]
        /// Adjusted summary diagnostic reporting effective coverage, if inherited docs were found.
        public let adjustedSummary: Diagnostic?
        /// Number of APIs reclassified as documented via inheritance.
        public let inheritedDocCount: Int

        /// Creates a Pass 2 results bundle.
        ///
        /// - Parameters:
        ///   - pass1Diagnostics: The original Pass 1 diagnostics.
        ///   - inheritedDiagnostics: Diagnostics for inherited documentation.
        ///   - usagePriorityDiagnostics: Usage-priority ranking diagnostics.
        ///   - adjustedSummary: Adjusted coverage summary, if applicable.
        ///   - inheritedDocCount: Count of inherited-doc APIs.
        public init(
            pass1Diagnostics: [Diagnostic],
            inheritedDiagnostics: [Diagnostic],
            usagePriorityDiagnostics: [Diagnostic],
            adjustedSummary: Diagnostic?,
            inheritedDocCount: Int
        ) {
            self.pass1Diagnostics = pass1Diagnostics
            self.inheritedDiagnostics = inheritedDiagnostics
            self.usagePriorityDiagnostics = usagePriorityDiagnostics
            self.adjustedSummary = adjustedSummary
            self.inheritedDocCount = inheritedDocCount
        }
    }

    // MARK: - Rule 1: Inherited documentation detection

    /// Classifies undocumented APIs that inherit documentation from protocol requirements.
    ///
    /// When a protocol requirement has a doc comment, default implementations in
    /// protocol extensions are considered "documented via inheritance". This method
    /// emits `doc-inherited` info diagnostics for such APIs and returns the
    /// remaining undocumented APIs that were not resolved.
    ///
    /// - Parameters:
    ///   - undocumentedAPIs: APIs flagged as undocumented by Pass 1.
    ///   - protocolRequirementDocs: Map of USR to whether the protocol requirement has a doc comment.
    /// - Returns: A tuple of inherited-doc diagnostics and remaining unresolved APIs.
    public static func classifyInheritedDocs(
        undocumentedAPIs: [UndocumentedAPI],
        protocolRequirementDocs: [String: Bool]
    ) -> (inherited: [Diagnostic], remaining: [UndocumentedAPI]) {
        var inherited: [Diagnostic] = []
        var remaining: [UndocumentedAPI] = []

        for api in undocumentedAPIs {
            if let usr = api.usr, protocolRequirementDocs[usr] == true {
                inherited.append(Diagnostic(
                    severity: .note,
                    message: "Public \(api.apiType) '\(api.name)' inherits documentation from protocol requirement",
                    filePath: api.filePath,
                    lineNumber: api.line,
                    columnNumber: 1,
                    ruleId: "doc-inherited",
                    suggestedFix: "Documentation is inherited from the protocol requirement. Add an explicit /// comment to override."
                ))
            } else {
                remaining.append(api)
            }
        }

        return (inherited, remaining)
    }

    // MARK: - Rule 2: Usage-priority ranking

    /// Ranks undocumented APIs by reference count to suggest documentation priorities.
    ///
    /// APIs with more references across the project are more impactful to document.
    /// Returns the top N `doc-usage-priority` info diagnostics sorted by descending
    /// reference count.
    ///
    /// - Parameters:
    ///   - undocumentedAPIs: Undocumented APIs remaining after inheritance classification.
    ///   - referenceCounts: Map of API name to reference count from the index.
    ///   - topN: Maximum number of priority suggestions to emit.
    /// - Returns: Up to `topN` `doc-usage-priority` info diagnostics.
    public static func rankByUsage(
        undocumentedAPIs: [UndocumentedAPI],
        referenceCounts: [String: Int],
        topN: Int = 10
    ) -> [Diagnostic] {
        let ranked = undocumentedAPIs
            .map { api in (api: api, count: referenceCounts[api.name] ?? 0) }
            .sorted { $0.count > $1.count }
            .prefix(topN)

        return ranked.compactMap { entry -> Diagnostic? in
            guard entry.count > 0 else { return nil }
            return Diagnostic(
                severity: .note,
                message: "Undocumented \(entry.api.apiType) '\(entry.api.name)' has \(entry.count) reference(s) — consider documenting it first",
                filePath: entry.api.filePath,
                lineNumber: entry.api.line,
                columnNumber: 1,
                ruleId: "doc-usage-priority",
                suggestedFix: "Add /// documentation comment above the declaration of '\(entry.api.name)'."
            )
        }
    }

    // MARK: - Adjusted summary

    /// Produces an adjusted coverage summary reporting both explicit and effective percentages.
    ///
    /// Effective coverage includes APIs documented via protocol inheritance.
    /// The threshold evaluation uses effective coverage when Pass 2 runs.
    ///
    /// - Parameters:
    ///   - totalAPIs: Total number of public APIs.
    ///   - explicitlyDocumented: APIs with explicit doc comments (Pass 1 count).
    ///   - inheritedCount: APIs documented via protocol inheritance (Pass 2 count).
    ///   - threshold: Coverage threshold percentage, if configured.
    /// - Returns: A summary diagnostic with explicit and effective percentages.
    public static func adjustedSummary(
        totalAPIs: Int,
        explicitlyDocumented: Int,
        inheritedCount: Int,
        threshold: Int?
    ) -> Diagnostic {
        let explicitPercent = totalAPIs > 0
            ? (explicitlyDocumented * 100) / totalAPIs
            : 100
        let effectiveDocumented = explicitlyDocumented + inheritedCount
        let effectivePercent = totalAPIs > 0
            ? (effectiveDocumented * 100) / totalAPIs
            : 100

        let passesThreshold: Bool
        if let threshold {
            passesThreshold = effectivePercent >= threshold
        } else {
            passesThreshold = effectiveDocumented >= totalAPIs
        }
        let severity: Diagnostic.Severity = passesThreshold ? .note : .warning

        return Diagnostic(
            severity: severity,
            message: "Documentation coverage: \(explicitPercent)% explicit (\(explicitlyDocumented)/\(totalAPIs)), \(effectivePercent)% effective (\(effectiveDocumented)/\(totalAPIs) including \(inheritedCount) inherited)",
            ruleId: "doc-coverage-summary"
        )
    }

    // MARK: - Graceful degradation

    /// Returns a note diagnostic indicating that the index-backed pass was skipped.
    ///
    /// Used when the index store is unavailable, misconfigured, or the
    /// `useIndexStore` configuration option is disabled. This ensures the quality
    /// gate never fails solely because of a missing index.
    ///
    /// - Returns: A `.note` severity diagnostic.
    public static func unavailableNote() -> Diagnostic {
        Diagnostic(
            severity: .note,
            message: "DocCoverage Pass 2 skipped: index store unavailable. Build the project to enable inherited-doc detection and usage-priority ranking.",
            ruleId: "doc-coverage.index-pass.skipped"
        )
    }
}
