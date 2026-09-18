import IJSDashboardCore

/// The terminal glyph for a gate status.
///
/// This lived on `ProjectSummary.GateStatus` itself until the sensing layer moved to
/// `quality-gate-corpus-kit` on 2026-09-17. `GateStatus` is a fact about the corpus — a checker
/// is failing, or the green was assembled from partial runs, or one full run confirmed it — and
/// that distinction belongs in the model. Which characters draw it does not: the same status is
/// rendered by this terminal UI, by a SwiftUI dashboard, and by an MCP server that returns it as
/// JSON and draws nothing at all.
///
/// So the glyph is an extension in the surface that wants glyphs. Nothing else changed; these are
/// the same three characters the model used to vend.
extension ProjectSummary.GateStatus {

    /// The status glyph: `✓` (full-confirmed), `✓*` (partial-confirmed), `✗`.
    ///
    /// The asterisk is load-bearing. A green assembled from several partial runs has never been
    /// confirmed by one full gate, and a reader who cannot tell the two apart will read `✓` as a
    /// stronger claim than the corpus supports.
    public var symbol: String {
        switch self {
        case .failing: return "\u{2717}"
        case .passingPartial: return "\u{2713}*"
        case .passingConfirmed: return "\u{2713}"
        }
    }
}
