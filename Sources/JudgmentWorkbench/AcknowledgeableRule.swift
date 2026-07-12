import Foundation

/// Where an acknowledgment marker must be written for its auditor to detect it.
public enum MarkerPlacement: Sendable, Equatable, Hashable {
    /// Appended to the flagged line as an end-of-line comment.
    ///
    /// Auditors with this placement match via substring `contains()` on the
    /// flagged line (verified: `IdiomAuditor.auditSource`,
    /// `SmellVisitor.emit`, `CustomRulesChecker.apply`,
    /// `VigilKit.CancellationScan`), so trailing text after the marker — a
    /// reason continuation — does not defeat detection.
    case endOfLine

    /// Inserted as a comment line directly above the flagged declaration.
    ///
    /// Used by auditors that look for the marker in the declaration's
    /// *leading trivia* (verified: `LegibilityAnalyzer.PublicSurfaceScanner`
    /// checks `node.leadingTrivia` line/block comments) — an end-of-line
    /// comment on the flagged line would land in trailing trivia and be
    /// invisible to them.
    case lineAbove
}

/// The rule→marker registry: how an advisory finding is acknowledged in place.
///
/// Each entry encodes an acknowledgment convention **verified against the
/// auditor's detection code**, not guessed:
///
/// | Rule family | Marker | Placement (verified detection) |
/// |---|---|---|
/// | `idiom.*` | `// idiom:exempt` | flagged line; `lines[line-1].contains(marker)` |
/// | `smell.*` | `// smell:exempt` | flagged declaration's line; `lines[line-1].contains(marker)` |
/// | origin `custom-rule` | `// custom:exempt` | matching line; `line.contains(marker)` |
/// | `legibility.over-public-symbol` | `// legibility:reserved <reason>` | leading trivia — its own line above the declaration |
/// | `concurrency.cancellation-checkpoint-after-loop` | `// concurrency:exempt` | loop line (or line above); `contains(marker)` |
///
/// Because every end-of-line detector uses `contains()`, a reason appended
/// after a bare marker (`// smell:exempt tuned for vDSP call shape`) still
/// matches — the reason rides along as comment continuation.
public struct AcknowledgeableRule: Sendable, Equatable, Hashable {
    /// The comment marker to write, including the leading `//` (e.g. `// idiom:exempt`).
    public let marker: String

    /// Whether the marker's syntax demands a reason after it
    /// (`// legibility:reserved <reason>`); bare exempt markers accept an
    /// optional reason as comment continuation.
    public let requiresReason: Bool

    /// Where the marker must be written for the auditor to see it.
    public let placement: MarkerPlacement

    /// Creates a registry entry.
    ///
    /// - Parameters:
    ///   - marker: The comment marker, including the leading `//`.
    ///   - requiresReason: Whether the marker syntax demands a reason.
    ///   - placement: Where the marker must be written.
    public init(marker: String, requiresReason: Bool, placement: MarkerPlacement) {
        self.marker = marker
        self.requiresReason = requiresReason
        self.placement = placement
    }

    /// Resolves the acknowledgment convention for a finding, or nil when the
    /// rule has no in-place acknowledgment path (not acknowledgeable from the
    /// inbox).
    ///
    /// Exact rule ids are matched first, then the `custom-rule` origin, then
    /// family prefixes — so a custom rule keeps its own escape hatch whatever
    /// id its author chose.
    ///
    /// - Parameters:
    ///   - ruleId: The finding's rule identifier (e.g. `idiom.empty-count`).
    ///   - origin: The finding's provenance tag (e.g. `custom-rule`), if any.
    /// - Returns: The verified marker convention, or nil.
    public static func `for`(ruleId: String, origin: String?) -> AcknowledgeableRule? {
        switch ruleId {
        case "legibility.over-public-symbol":
            // Verified: PublicSurfaceVisitor.hasReservedMarker scans the
            // declaration's leading trivia for "legibility:reserved".
            return AcknowledgeableRule(
                marker: "// legibility:reserved", requiresReason: true, placement: .lineAbove)
        case "concurrency.cancellation-checkpoint-after-loop":
            // Verified: VigilKit.CancellationScan.lineHasCancellationExempt
            // accepts the loop line or the line directly above via contains().
            return AcknowledgeableRule(
                marker: "// concurrency:exempt", requiresReason: false, placement: .endOfLine)
        default:
            break
        }
        if origin == "custom-rule" {
            // Verified: CustomRulesChecker.apply — line.contains("// custom:exempt").
            return AcknowledgeableRule(
                marker: "// custom:exempt", requiresReason: false, placement: .endOfLine)
        }
        if ruleId.hasPrefix("idiom.") {
            // Verified: IdiomAuditor.auditSource — lines[line-1].contains("// idiom:exempt").
            return AcknowledgeableRule(
                marker: "// idiom:exempt", requiresReason: false, placement: .endOfLine)
        }
        if ruleId.hasPrefix("smell.") {
            // Verified: SmellVisitor.emit — lines[line-1].contains("// smell:exempt").
            return AcknowledgeableRule(
                marker: "// smell:exempt", requiresReason: false, placement: .endOfLine)
        }
        return nil
    }
}
