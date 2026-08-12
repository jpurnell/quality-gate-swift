import Foundation

/// A `// stochastic:exempt` marker, and whether it says why.
///
/// ## Why a bare marker is itself a finding
///
/// The marker used to be recognised by substring: any occurrence suppressed the diagnostic, and
/// nothing distinguished a considered decision from *"the auditor complained here."* Two defects
/// in one release hid behind that, both with bare markers, and each cost a misdiagnosis before
/// the real cause was found — a GPU path where a configured `seed` was silently inert, and a
/// robust optimiser redrawing 92 of 100 scenarios on every call, so two runs of the same
/// optimisation solved two different problems. The second was investigated as load-dependent
/// flakiness and then as a stale build; after seeding, two intermittent failures became
/// reproducible and revealed a real constraint-accuracy defect the randomness had been hiding.
///
/// ## What this does and does not prove
///
/// It checks that a reason was written, not that the reason is true — and the failure that
/// prompted it was a line whose comment would have passed had one been written. That criticism
/// is correct and is the reason this is a warning rather than an error, and the reason
/// verifying the justification *names a seeded alternative* is recorded as the follow-on. What
/// it buys is that the two populations become distinguishable at all, which today they are not
/// at any cost short of reading every marker by hand.
public struct ExemptMarker: Sendable, Equatable {

    /// The text following the keyword, trimmed.
    public let trailingText: String

    /// Whether that text amounts to a reason.
    public let hasJustification: Bool

    /// Reads a source line for the marker.
    ///
    /// - Parameters:
    ///   - line: The source line as written.
    ///   - keyword: The marker token, e.g. `stochastic:exempt`.
    /// - Returns: The marker, or `nil` when the line does not carry one.
    public static func parse(line: String, keyword: String) -> ExemptMarker? {
        guard let range = line.range(of: keyword) else { return nil }
        let trailing = String(line[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ExemptMarker(
            trailingText: trailing,
            hasJustification: isJustification(trailing))
    }

    /// Whether trailing text is a reason rather than punctuation or another marker.
    ///
    /// Two things are deliberately not reasons. **Punctuation alone** — `// stochastic:exempt —`
    /// is a dash, and a dash explains nothing. **Another suppression marker** — a line reading
    /// `stochastic:exempt fp-safety:disable` silences two auditors while explaining neither, and
    /// letting one marker's presence satisfy the other's requirement would make the pair cheaper
    /// to write than either alone.
    static func isJustification(_ text: String) -> Bool {
        var remaining = text
        // Strip sibling markers of the `family:action` shape the other auditors use.
        while let marker = remaining.range(
            of: #"[a-z][a-z0-9-]*:[a-z][a-z0-9-]*"#, options: .regularExpression) {
            remaining.removeSubrange(marker)
        }
        return remaining.contains { $0.isLetter || $0.isNumber }
    }
}
