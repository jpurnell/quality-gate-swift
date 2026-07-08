import Foundation

/// Where a module orientation card's prose came from.
///
/// The factual fields (`reliedOnBy`, `role`) never depend on this — they are
/// always exact. Today only the deterministic `template` tier exists; the planned
/// durability order (fresh LLM > preserved LLM > template) will add `.llm` /
/// `.preservedLLM` cases when the per-module prose generator lands and references
/// them.
public enum ProseSource: String, Sendable, Codable, Equatable {
    /// Deterministic fallback synthesized from the module's role and doc.
    case template
}

/// A per-module "orientation card": what a module does, why, and what relies on
/// it — the substrate for the dashboard's module-orientation section and a future
/// `ONBOARDING.md`.
///
/// Produced by the LegibilityAnalyzer from the module graph and written to the
/// corpus inside an ``OrientationReport``. `reliedOnBy` is the factual anchor: the
/// exact set of modules that reference this one, so "what relies on it" is always
/// correct even when no prose exists.
public struct ModuleOrientationCard: Sendable, Codable, Equatable {
    /// The module this card describes.
    public let moduleID: String
    /// Prose: what the module does. `nil` → render from `role`.
    public let whatItDoes: String?
    /// Prose: why it exists. `nil` → omit the line.
    public let why: String?
    /// Modules that rely on this one (its dependents), sorted — factual, exact.
    public let reliedOnBy: [String]
    /// One-word structural role inferred from the module's position in the graph.
    public let role: String
    /// Where `whatItDoes` / `why` came from (durability).
    public let source: ProseSource
    /// Timestamp of the run that produced this card.
    public let generatedAt: Date

    /// Creates a module orientation card.
    public init(
        moduleID: String,
        whatItDoes: String?,
        why: String?,
        reliedOnBy: [String],
        role: String,
        source: ProseSource,
        generatedAt: Date
    ) {
        self.moduleID = moduleID
        self.whatItDoes = whatItDoes
        self.why = why
        self.reliedOnBy = reliedOnBy
        self.role = role
        self.source = source
        self.generatedAt = generatedAt
    }
}

/// A per-run orientation report emitted to the IJS corpus alongside
/// `CheckResultMetadata`, holding one ``ModuleOrientationCard`` per module in the
/// analyzed package.
///
/// File convention: `telemetry/<projectID>/YYYY-MM-DD/HHmmss_orientation.json`.
/// Mirrors `ComplexityReport`'s per-run/per-module shape so the dashboard reads it
/// the same way and matches a module by `ModuleOrientationCard.moduleID`.
public struct OrientationReport: Sendable, Codable, Equatable {
    /// Project identifier matching the corpus hierarchy.
    public let projectID: String
    /// Timestamp of the gate run that produced this report.
    public let timestamp: Date
    /// One card per module in the package.
    public let cards: [ModuleOrientationCard]

    /// Creates an orientation report.
    public init(projectID: String, timestamp: Date, cards: [ModuleOrientationCard]) {
        self.projectID = projectID
        self.timestamp = timestamp
        self.cards = cards
    }

    /// The card for a specific module, if present.
    public func card(for moduleID: String) -> ModuleOrientationCard? {
        cards.first { $0.moduleID == moduleID }
    }
}
