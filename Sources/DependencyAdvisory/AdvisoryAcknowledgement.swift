import Foundation
import QualityGateCore

/// Applies `dependencyAudit.acknowledgedAdvisories` to findings, and keeps the account.
///
/// ## Why not `// SECURITY:`
///
/// That marker sits next to code a reader is looking at. `Package.resolved` is JSON with no line
/// above, and an exemption with no expiry on a dependency nobody is looking at is how a 2023
/// advisory is still pinned in 2026. So an acknowledgement names the advisory and the package,
/// gives a reason held to ``JustificationValidator`` — the standard every other justification in
/// the gate meets — and carries an `until`.
///
/// ## Why `until` is compared to the snapshot, not to today
///
/// An acknowledgement that expired on a calendar date would make the same tree pass on Monday
/// and fail on Tuesday. Compared to the snapshot's `fetched`, it expires when the gate's
/// *knowledge* moves past it: the same tree with the same snapshot gives the same answer on any
/// day, and a refresh — which is when a changed advisory would arrive — is what re-opens the
/// question.
struct AcknowledgementLedger: Sendable {

    /// What an acknowledgement did to one finding.
    enum Decision: Sendable, Equatable {
        /// No entry names this advisory on this package.
        case none
        /// Recorded as an override; the finding is not reported.
        case accepted(AcknowledgedAdvisory)
        /// An entry matched and was not accepted; the finding is reported and says why.
        case rejected(String)
        /// An entry matched and has expired; the finding is reported, and so is the expiry.
        case expired
    }

    private let entries: [AcknowledgedAdvisory]
    private var matched: Set<Int> = []
    private var expired: [(index: Int, fetched: String)] = []

    init(entries: [AcknowledgedAdvisory]) {
        self.entries = entries
    }

    /// Decides what the configured acknowledgements say about `advisory` on the pin at
    /// `pinIdentity`, given a snapshot fetched on `fetched`.
    mutating func decide(advisory: Advisory, pinIdentity: String, fetched: String) -> Decision {
        let names = Set(([advisory.id] + advisory.aliases).map { $0.lowercased() })
        let spellings = AdvisoryMatcher.spellings(of: pinIdentity.lowercased())
        guard let index = entries.firstIndex(where: { entry in
            names.contains(entry.id.trimmingCharacters(in: .whitespaces).lowercased())
                && spellings.contains(AdvisoryMatcher.identity(ofLocation: entry.package).lowercased())
        }) else { return .none }

        matched.insert(index)
        let entry = entries[index]
        if let why = Self.rejection(of: entry) { return .rejected(why) }
        guard let until = AdvisoryDate(entry.until), let fetchedDate = AdvisoryDate(fetched), until > fetchedDate else {
            if !expired.contains(where: { $0.index == index }) { expired.append((index, fetched)) }
            return .expired
        }
        return .accepted(entry)
    }

    /// Why `entry` cannot be accepted as written, or `nil` when it can.
    static func rejection(of entry: AcknowledgedAdvisory) -> String? {
        let reason = entry.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return "it gives no reason" }
        switch JustificationValidator().validate(reason, keyword: "") {
        case .valid, .duplicate: break
        case .tooShort(let wordCount): return "its reason has \(wordCount) words and 8 are required"
        case .generic(let phrase): return "its reason is the stock phrase '\(phrase)'"
        }
        let until = entry.until.trimmingCharacters(in: .whitespaces)
        guard !until.isEmpty else { return "it has no `until` date" }
        guard AdvisoryDate(until) != nil else { return "its `until` date '\(until)' is not YYYY-MM-DD" }
        return nil
    }

    /// One finding per acknowledgement that matched and had expired.
    func expiredDiagnostics() -> [Diagnostic] {
        expired.sorted { $0.index < $1.index }.map { item in
            let entry = entries[item.index]
            return Diagnostic(
                severity: .warning,
                message: "The acknowledgement of \(entry.id) for \(entry.package) expired on \(entry.until): the "
                    + "advisory snapshot in use was fetched \(item.fetched). The finding is reported again — fix "
                    + "the pin, or renew the acknowledgement with a reason that is still true.",
                filePath: AdvisoryAudit.configurationFile,
                ruleId: AdvisoryRule.acknowledgementExpired)
        }
    }

    /// One finding per acknowledgement no finding matched.
    func unusedDiagnostics() -> [Diagnostic] {
        entries.indices.filter { !matched.contains($0) }.map { index in
            let entry = entries[index]
            return Diagnostic(
                severity: .warning,
                message: "`dependencyAudit.acknowledgedAdvisories` acknowledges \(entry.id) for \(entry.package), "
                    + "and no pin here is affected by it. Remove the entry.",
                filePath: AdvisoryAudit.configurationFile,
                ruleId: AdvisoryRule.acknowledgementUnused)
        }
    }
}
