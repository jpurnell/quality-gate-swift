import Foundation

/// Which engine produced a pulse narrative, in descending order of quality.
///
/// The durability chain tries providers in this order and records the rung that
/// actually spoke, so the dashboard can badge the narrative honestly — a
/// cloud-authored analysis, an on-device fallback, or a carried-forward prior.
public enum NarrativeSource: String, Sendable, Codable, Equatable, CaseIterable {
    /// Cloud LLM (Anthropic Claude) — the primary, highest-quality engine.
    case claude
    /// Apple Foundation Models, generated entirely on-device — the offline/no-key fallback.
    case onDeviceLLM
    /// The prior pulse's narrative, carried forward verbatim when no engine could run.
    case preservedLLM
    /// A deterministic, non-LLM synthesis — the last resort.
    case template
}
