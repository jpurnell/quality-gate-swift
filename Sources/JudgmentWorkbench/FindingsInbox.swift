import Foundation
import CorpusKit
import QualityGateCore

/// One advisory finding from the latest run, ready to be worked in the inbox.
public struct InboxItem: Sendable, Equatable, Hashable {
    /// The rule that produced the finding, when the diagnostic carried one.
    public let ruleId: String?
    /// The finding's human-readable message.
    public let message: String
    /// Absolute path of the flagged file.
    public let filePath: String
    /// 1-based flagged line number.
    public let lineNumber: Int
    /// The finding's provenance tag (e.g. `custom-rule`), if any.
    public let origin: String?
    /// The verified acknowledgment convention, or nil when the rule has no
    /// in-place acknowledgment path.
    public let marker: AcknowledgeableRule?

    /// Whether choosing "acknowledge" on this item can succeed.
    public var isAcknowledgeable: Bool { marker != nil }

    /// Creates an inbox item.
    ///
    /// - Parameters:
    ///   - ruleId: The rule that produced the finding, if known.
    ///   - message: The finding's message.
    ///   - filePath: Absolute path of the flagged file.
    ///   - lineNumber: 1-based flagged line number.
    ///   - origin: Provenance tag, if any.
    ///   - marker: The resolved acknowledgment convention, if any.
    public init(
        ruleId: String?,
        message: String,
        filePath: String,
        lineNumber: Int,
        origin: String?,
        marker: AcknowledgeableRule?
    ) {
        self.ruleId = ruleId
        self.message = message
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.origin = origin
        self.marker = marker
    }
}

/// Typed failures from ``FindingsInbox``.
public enum FindingsInboxError: Error, Sendable, Equatable {
    /// The rule has no registered acknowledgment marker — the finding cannot
    /// be acknowledged from the inbox.
    case notAcknowledgeable(ruleId: String?)
    /// The rule's marker syntax requires a reason and none (or a blank one)
    /// was supplied.
    case reasonRequired(ruleId: String?)
}

/// The findings inbox: the latest run's advisory findings, acknowledgeable in
/// place.
///
/// Choosing acknowledge writes the marker line at the flagged location via
/// ``MarkerWriter`` — the fix machinery pointed at judgment — so the next
/// audit records a `DiagnosticOverride` instead of the finding. The magic
/// comment becomes the artifact of the interaction instead of its
/// prerequisite.
public enum FindingsInbox {

    /// Extracts the latest run's advisory findings as inbox items.
    ///
    /// Included: diagnostics of severity `.note` that carry both a file path
    /// and a line number. Excluded: errors and warnings (they gate, they are
    /// not "acknowledged"), locationless notes (nowhere to write a marker),
    /// and `baseline`-origin notes (decaying debt is the re-verify queue's
    /// business). Items are deduplicated and sorted by file path, then line
    /// number (then rule id and message for full determinism).
    ///
    /// - Parameter metadata: The run's recorded results.
    /// - Returns: Deduplicated, sorted inbox items with resolved markers.
    public static func items(from metadata: CheckResultMetadata) -> [InboxItem] {
        items(fromResults: metadata.results)
    }

    /// Extracts advisory findings from a set of checker results directly.
    ///
    /// Same filtering as ``items(from:)``, but over a caller-assembled result
    /// list — letting the dashboard build a *composite* inbox (each checker's
    /// latest standard-mode run) rather than a single run's snapshot.
    ///
    /// - Parameter results: The checker results to scan.
    /// - Returns: Deduplicated, sorted inbox items with resolved markers.
    public static func items(fromResults results: [CheckResult]) -> [InboxItem] {
        var seen = Set<InboxItem>()
        var items: [InboxItem] = []
        for result in results {
            for diagnostic in result.diagnostics {
                guard diagnostic.severity == .note,
                      let filePath = diagnostic.filePath,
                      let lineNumber = diagnostic.lineNumber,
                      diagnostic.origin != "baseline" else { continue }
                let marker = diagnostic.ruleId.flatMap {
                    AcknowledgeableRule.for(ruleId: $0, origin: diagnostic.origin)
                }
                let item = InboxItem(
                    ruleId: diagnostic.ruleId,
                    message: diagnostic.message,
                    filePath: filePath,
                    lineNumber: lineNumber,
                    origin: diagnostic.origin,
                    marker: marker
                )
                if seen.insert(item).inserted {
                    items.append(item)
                }
            }
        }
        return items.sorted { lhs, rhs in
            if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
            if lhs.lineNumber != rhs.lineNumber { return lhs.lineNumber < rhs.lineNumber }
            let lhsRule = lhs.ruleId ?? ""
            let rhsRule = rhs.ruleId ?? ""
            if lhsRule != rhsRule { return lhsRule < rhsRule }
            return lhs.message < rhs.message
        }
    }

    /// Acknowledges a finding in place: writes its marker at the flagged
    /// location, so re-auditing records a `DiagnosticOverride` instead of the
    /// finding.
    ///
    /// - Parameters:
    ///   - item: The inbox item to acknowledge.
    ///   - reason: Human rationale. Required when the marker's syntax demands
    ///     one (`// legibility:reserved <reason>`); otherwise appended after
    ///     the bare marker as comment continuation (safe — the end-of-line
    ///     detectors match via substring `contains()`).
    /// - Throws: ``FindingsInboxError/notAcknowledgeable(ruleId:)`` when the
    ///   rule has no marker, ``FindingsInboxError/reasonRequired(ruleId:)``
    ///   when a required reason is missing or blank, or ``MarkerWriterError``
    ///   / file-system errors from the write.
    public static func acknowledge(item: InboxItem, reason: String? = nil) throws {
        guard let rule = item.marker else {
            throw FindingsInboxError.notAcknowledgeable(ruleId: item.ruleId)
        }
        let normalized = MarkerWriter.normalizedReason(reason)
        if rule.requiresReason, normalized == nil {
            throw FindingsInboxError.reasonRequired(ruleId: item.ruleId)
        }
        try MarkerWriter.applyToFile(
            marker: rule.marker,
            reason: normalized,
            placement: rule.placement,
            line: item.lineNumber,
            path: item.filePath
        )
    }
}
