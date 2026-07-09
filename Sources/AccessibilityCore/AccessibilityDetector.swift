import QualityGateCore

/// A single source file handed to a detector for analysis.
///
/// Frontend-neutral: it carries only the raw source, its path, and the exemption
/// patterns in effect. Each detector parses the source itself, so the core stays free
/// of any parser dependency.
public struct SourceUnit: Sendable {
    /// Absolute path to the source file (used in diagnostics).
    public let fileName: String
    /// The file's Swift source text.
    public let source: String
    /// Comment patterns (e.g. `// SAFETY:`) that suppress a diagnostic on the next line.
    public let exemptionPatterns: [String]

    /// Creates a source unit for a detector to analyze.
    public init(fileName: String, source: String, exemptionPatterns: [String]) {
        self.fileName = fileName
        self.source = source
        self.exemptionPatterns = exemptionPatterns
    }
}

/// The diagnostics and exemption overrides a detector produced for one ``SourceUnit``.
public struct DetectionResult: Sendable {
    /// Accessibility violations found in the source unit.
    public let diagnostics: [Diagnostic]
    /// Violations that were suppressed by an exemption comment.
    public let overrides: [DiagnosticOverride]

    /// Creates a detection result.
    public init(diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        self.diagnostics = diagnostics
        self.overrides = overrides
    }
}

/// A per-frontend accessibility detector.
///
/// Detectors are stateless and pure: given a ``SourceUnit`` they return a
/// ``DetectionResult`` with no I/O or shared state. The orchestrator resolves which
/// frontends apply to a file (via ``FrontendResolver``) and runs the matching detectors,
/// so one auditor stays a single engine across SwiftUI, CLI, and future frontends.
public protocol AccessibilityDetector: Sendable {
    /// The frontend this detector audits.
    var frontend: Frontend { get }

    /// Detect accessibility violations in one source unit.
    func detect(in unit: SourceUnit) -> DetectionResult
}
