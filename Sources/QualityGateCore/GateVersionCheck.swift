import Foundation

/// Compares the running binary's build identity against a repo's configured
/// minimum (Phase 0.6, retires the binary half of L6).
///
/// A stale installed binary silently runs old rules — the gate looks green
/// under rules that no longer exist. Repos ratchet `minimumGateVersion` when
/// they depend on new rules; a stale binary then warns (or fails under
/// `--strict`) instead of pretending to pass.
public enum GateVersionCheck {
    /// The result of comparing the binary against the configured pin.
    public enum Outcome: Equatable, Sendable {
        /// No `minimumGateVersion` configured.
        case noPin
        /// The binary is at least as new as the pin (or the build date is
        /// unknown — dev builds never block).
        case satisfied
        /// The binary predates the pin. Both identities are named so the
        /// message can say exactly what to update.
        case stale(installed: String, required: String)
        /// The pin could not be parsed as a date — surfaced, never ignored.
        case unparseablePin(String)
    }

    /// Compares a configured minimum against the binary's build date.
    ///
    /// - Parameters:
    ///   - minimum: The `minimumGateVersion` pin — `YYYY-MM-DD` or full
    ///     ISO8601. `nil` means no pin.
    ///   - buildDate: The binary's ISO8601 build timestamp (from BuildStamp).
    /// - Returns: The comparison outcome.
    public static func check(minimum: String?, buildDate: String) -> Outcome {
        guard let minimum, !minimum.isEmpty else { return .noPin }
        guard let pinDate = parse(minimum) else { return .unparseablePin(minimum) }
        guard let installedDate = parse(buildDate) else {
            // A dev build without a stamp must never block the gate.
            return .satisfied
        }
        return installedDate >= pinDate
            ? .satisfied
            : .stale(installed: buildDate, required: minimum)
    }

    /// Parses `YYYY-MM-DD` (midnight UTC) or full ISO8601 timestamps.
    private static func parse(_ value: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: value) { return date }
        let dayOnly = ISO8601DateFormatter()
        dayOnly.formatOptions = [.withFullDate]
        return dayOnly.date(from: value)
    }
}
