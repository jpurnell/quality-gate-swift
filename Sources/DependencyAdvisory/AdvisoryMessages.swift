import Foundation
import QualityGateCore

/// The wording of each finding. Kept in one place so that the tests which assert whole messages
/// have one place to disagree with.
enum AdvisoryMessages {

    /// `… Pin: <identity>. Advisory data as of <date>.` — every finding ends by saying which pin
    /// and how old the knowledge is, because an advisory is a dated fact and so is its absence.
    private static func provenance(_ context: AdvisoryAudit.PinContext, matchedBy name: String? = nil) -> String {
        let matched = name.map { ", matched by name — the advisory names the package `\($0)`, not a URL" } ?? ""
        return "Pin: \(context.identity)\(matched). Advisory data as of \(context.fetched)."
    }

    /// The message for a pin inside an affected range.
    static func vulnerable(_ finding: AdvisoryAudit.Finding) -> String {
        let advisory = finding.candidate.advisory
        let version = finding.context.pin.version ?? ""
        let fix = finding.hit.fixed.map { "fixed in \($0)" } ?? "no fixed version"
        let byName = finding.candidate.kind == .name ? finding.candidate.advisoryName : nil
        return "\(finding.context.pin.identity) \(version) is affected by \(advisory.id) (\(qualifiers(advisory))): "
            + "\(sentence(advisory.summary)) Affected: \(finding.hit.range); \(fix). "
            + "\(provenance(finding.context, matchedBy: byName)) [CWE-1395]"
    }

    /// Aliases, then GitHub's label — or, with no label, the fact of that and the vector quoted.
    private static func qualifiers(_ advisory: Advisory) -> String {
        var severity = advisory.severityLabel ?? "no severity recorded"
        if advisory.severityLabel == nil, let vector = advisory.cvssVector { severity += "; \(vector)" }
        return (advisory.aliases + [severity]).joined(separator: ", ")
    }

    /// The summary as one sentence, whatever punctuation it arrived with.
    private static func sentence(_ summary: String) -> String {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "No summary was published." : text + "."
    }

    /// What to do about an affected pin.
    static func fix(_ finding: AdvisoryAudit.Finding) -> String {
        let identity = finding.context.pin.identity
        if let fixed = finding.hit.fixed {
            return "Update \(identity) to \(fixed) or later: `swift package update \(identity)`"
        }
        return "No release fixes this. Replace the dependency, or acknowledge \(finding.candidate.advisory.id) "
            + "under `dependencyAudit.acknowledgedAdvisories` with a reason and an `until` date."
    }

    /// The finding for a pin with no version on a package some advisory names.
    ///
    /// A branch or a bare revision cannot be compared to a version range, and the Swift export
    /// has no `GIT` ranges to compare a commit against. The rule cannot say the pin is safe and
    /// will not imply it.
    static func unversioned(_ context: AdvisoryAudit.PinContext, advisories ids: [String]) -> Diagnostic {
        let pinned: String
        if let branch = context.pin.branch {
            pinned = "pinned to branch '\(branch)', which has no version to compare"
        } else if let version = context.pin.version {
            pinned = "pinned to '\(version)', which is not a version that can be compared"
        } else {
            pinned = "pinned to a bare revision, which has no version to compare"
        }
        let shown = ids.prefix(5).joined(separator: ", ") + (ids.count > 5 ? ", and \(ids.count - 5) more" : "")
        let records = ids.count == 1 ? "1 advisory record names" : "\(ids.count) advisory records name"
        return Diagnostic(
            severity: .warning,
            message: "\(context.pin.identity) is \(pinned), and \(records) the package (\(shown)). The pin is not "
                + "known to be affected and not known to be safe. \(provenance(context))",
            filePath: context.lockfile,
            lineNumber: context.pin.line,
            ruleId: AdvisoryRule.unevaluable)
    }

    /// The finding for a range with a bound that is not a version.
    static func unevaluable(_ context: AdvisoryAudit.PinContext, advisory: Advisory, bound: String) -> Diagnostic {
        Diagnostic(
            severity: .warning,
            message: "\(context.pin.identity) \(context.pin.version ?? "") could not be compared against "
                + "\(advisory.id): the range bound '\(bound)' is not a version. The advisory is neither reported "
                + "nor cleared. \(provenance(context))",
            filePath: context.lockfile,
            lineNumber: context.pin.line,
            ruleId: AdvisoryRule.unevaluable)
    }
}
