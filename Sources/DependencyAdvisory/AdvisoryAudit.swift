import Foundation
import QualityGateCore

/// The denominators of one run. Every number is a denominator for the one after it.
struct AdvisoryTally: Sendable, Equatable {
    /// Lockfiles read.
    var lockfiles = 0
    /// Pins across them. The same package pinned in two lockfiles is two pins.
    var pins = 0
    /// Pins that are not one of the author's own packages.
    var thirdPartyPins = 0
    /// Pins with a version that could be compared.
    var evaluablePins = 0
    /// Pins on a branch, a bare revision, or a tag that is not a version.
    var unevaluablePins = 0
    /// Pins at least one advisory reaches, acknowledged or not.
    var affectedPins = 0
    /// Distinct advisories reaching at least one pin.
    var advisories: Set<String> = []
    /// Findings an acknowledgement excused.
    var acknowledged = 0
    /// Withdrawn records in the snapshot, which are never matched.
    var withdrawnRecords = 0
    /// Third-party pins no snapshot was available to check.
    var notChecked = 0
}

/// What the hermetic audit concluded.
struct AdvisoryAuditOutcome: Sendable {
    /// The findings, then the coverage note.
    let diagnostics: [Diagnostic]
    /// Acknowledged findings, recorded rather than dropped.
    let overrides: [DiagnosticOverride]
    /// Failed on any error, warning on any warning, otherwise passed.
    let status: CheckResult.Status
    /// The denominators.
    let tally: AdvisoryTally
    /// The snapshot the findings were computed from, when there was one.
    let snapshot: (snapshot: AdvisorySnapshot, origin: SnapshotOrigin)?
}

/// The check itself: lockfiles against a snapshot. No file, clock or network is read here —
/// the same arguments give the same outcome on any machine on any day.
enum AdvisoryAudit {

    /// Where findings about configuration point.
    static let configurationFile = ".quality-gate.yml"

    /// Audits `lockfiles` against the newer of the two snapshots.
    ///
    /// - Parameters:
    ///   - lockfiles: The parsed lockfiles.
    ///   - unreadable: Paths of lockfiles that could not be parsed; each is reported.
    ///   - bundled: The snapshot shipped with the gate, if any.
    ///   - committed: The snapshot committed in the repository, if any.
    ///   - configuration: Acknowledgements, own packages, and the committed snapshot's path.
    static func run(
        lockfiles: [Lockfile],
        unreadable: [String] = [],
        bundled: SnapshotCandidate?,
        committed: SnapshotCandidate?,
        configuration: DependencyAuditorConfig
    ) -> AdvisoryAuditOutcome {
        var run = Run(configuration: configuration)
        let chosen = run.choose(bundled: bundled, committed: committed)
        run.count(lockfiles)

        if let chosen {
            run.match(lockfiles, against: chosen.snapshot)
            run.reportAcknowledgements()
        } else {
            run.reportNoSnapshot()
        }
        run.reportUnreadable(unreadable)
        run.diagnostics.append(run.coverageNote(chosen))

        return AdvisoryAuditOutcome(
            diagnostics: run.diagnostics, overrides: run.overrides,
            status: status(of: run.diagnostics), tally: run.tally, snapshot: chosen)
    }

    /// Failed on any error, warning on any warning, otherwise passed.
    static func status(of diagnostics: [Diagnostic]) -> CheckResult.Status {
        if diagnostics.contains(where: { $0.severity == .error }) { return .failed }
        if diagnostics.contains(where: { $0.severity == .warning }) { return .warning }
        return .passed
    }

    /// The newer of two usable snapshots; the committed one on a tie, because it is the one the
    /// tree determines.
    static func newer(
        _ candidates: [(snapshot: AdvisorySnapshot, origin: SnapshotOrigin)]
    ) -> (snapshot: AdvisorySnapshot, origin: SnapshotOrigin)? {
        candidates.max { left, right in
            if left.snapshot.fetched != right.snapshot.fetched { return left.snapshot.fetched < right.snapshot.fetched }
            return left.origin == .bundled && right.origin == .committed
        }
    }

    /// The distinct Swift packages the snapshot's live records name.
    ///
    /// A record filed under a bare name is counted with the repository of that name when another
    /// record files one, and on its own otherwise — `swift-nio-http2` and
    /// `github.com/apple/swift-nio-http2` are one package filed two ways.
    static func packages(in snapshot: AdvisorySnapshot) -> Set<String> {
        let names = snapshot.advisories
            .filter { $0.withdrawn == nil }
            .flatMap(\.swiftAffected)
            .map { AdvisoryMatcher.identity(ofLocation: $0.name).lowercased() }
        var packages = Set(names.filter { $0.contains("/") })
        let lastComponents = Set(packages.compactMap { $0.split(separator: "/").last.map(String.init) })
        for bare in names where !bare.contains("/") && !lastComponents.contains(bare) {
            packages.insert(bare)
        }
        return packages
    }

    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }
}

extension AdvisoryAudit {

    /// The state one audit accumulates.
    struct Run {
        let configuration: DependencyAuditorConfig
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        var tally = AdvisoryTally()
        var acknowledgements: AcknowledgementLedger

        init(configuration: DependencyAuditorConfig) {
            self.configuration = configuration
            self.acknowledgements = AcknowledgementLedger(entries: configuration.acknowledgedAdvisories)
        }

        // MARK: Snapshot

        /// Picks the snapshot to use, reporting any candidate that was refused.
        mutating func choose(
            bundled: SnapshotCandidate?, committed: SnapshotCandidate?
        ) -> (snapshot: AdvisorySnapshot, origin: SnapshotOrigin)? {
            var usable: [(snapshot: AdvisorySnapshot, origin: SnapshotOrigin)] = []
            for candidate in [committed, bundled].compactMap({ $0 }) {
                switch candidate.decoded {
                case .success(let snapshot):
                    usable.append((snapshot, candidate.origin))
                case .failure(let problem):
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "The \(candidate.origin.rawValue) advisory snapshot is not usable: \(problem.reason). "
                            + "No advisory finding is reported from it.",
                        filePath: candidate.origin == .committed ? candidate.path : nil,
                        ruleId: AdvisoryRule.snapshotCorrupt))
                }
            }
            return AdvisoryAudit.newer(usable)
        }

        mutating func reportNoSnapshot() {
            tally.notChecked = tally.thirdPartyPins
            guard tally.thirdPartyPins > 0 else { return }
            let pins = AdvisoryAudit.plural(tally.thirdPartyPins, "third-party pin")
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "\(pins) in \(AdvisoryAudit.plural(tally.lockfiles, "lockfile")) "
                    + "\(tally.thirdPartyPins == 1 ? "was" : "were") not checked against any advisory: no advisory "
                    + "snapshot is available — none is bundled with this gate and none is committed at "
                    + "`\(configuration.advisorySnapshotPath)`. Run `quality-gate advisories refresh`.",
                ruleId: AdvisoryRule.noSnapshot))
        }

        // MARK: Counting

        mutating func count(_ lockfiles: [Lockfile]) {
            tally.lockfiles = lockfiles.count
            let own = configuration.ownPackages.map { AdvisoryMatcher.identity(ofLocation: $0).lowercased() }
            for pin in lockfiles.flatMap(\.pins) {
                tally.pins += 1
                let identity = AdvisoryMatcher.identity(ofLocation: pin.location).lowercased()
                if !own.contains(where: { !$0.isEmpty && (identity == $0 || identity.hasPrefix($0 + "/")) }) {
                    tally.thirdPartyPins += 1
                }
                if pin.version.flatMap(AdvisoryVersion.init) != nil {
                    tally.evaluablePins += 1
                } else {
                    tally.unevaluablePins += 1
                }
            }
        }

        mutating func reportUnreadable(_ paths: [String]) {
            for path in paths {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "`\(path)` could not be read as a lockfile, so its pins were not checked against "
                        + "any advisory.",
                    filePath: path,
                    ruleId: AdvisoryRule.unevaluable))
            }
        }

        // MARK: Matching

        mutating func match(_ lockfiles: [Lockfile], against snapshot: AdvisorySnapshot) {
            let live = snapshot.advisories.filter { $0.withdrawn == nil }
            tally.withdrawnRecords = snapshot.advisories.count - live.count
            for lockfile in lockfiles {
                for pin in lockfile.pins {
                    match(PinContext(pin: pin, lockfile: lockfile.path, fetched: snapshot.fetched), against: live)
                }
            }
        }

        /// Reports what the live advisories say about one pin.
        private mutating func match(_ context: PinContext, against advisories: [Advisory]) {
            let naming = advisories.compactMap { advisory -> Candidate? in
                Candidate(advisory: advisory, pinIdentity: context.identity)
            }
            guard !naming.isEmpty else { return }

            guard let text = context.pin.version, let version = AdvisoryVersion(text) else {
                diagnostics.append(AdvisoryMessages.unversioned(context, advisories: naming.map(\.advisory.id)))
                return
            }

            var affected = false
            for candidate in naming {
                switch candidate.verdict(for: version, text: text) {
                case .clear:
                    continue
                case .unevaluable(let bound):
                    diagnostics.append(AdvisoryMessages.unevaluable(context, advisory: candidate.advisory, bound: bound))
                case .affected(let hit):
                    affected = true
                    tally.advisories.insert(candidate.advisory.id)
                    report(Finding(context: context, candidate: candidate, hit: hit))
                }
            }
            if affected { tally.affectedPins += 1 }
        }

        /// Reports one affected pin, unless an acknowledgement excuses it.
        private mutating func report(_ finding: Finding) {
            let ruleId = finding.candidate.kind == .url ? AdvisoryRule.vulnerablePin : AdvisoryRule.vulnerablePinByName
            let decision = acknowledgements.decide(
                advisory: finding.candidate.advisory, pinIdentity: finding.context.identity, fetched: finding.context.fetched)

            if case .accepted(let entry) = decision {
                tally.acknowledged += 1
                overrides.append(DiagnosticOverride(
                    ruleId: ruleId,
                    justification: "\(finding.candidate.advisory.id) on \(finding.context.identity), acknowledged until "
                        + "\(entry.until): \(entry.reason.trimmingCharacters(in: .whitespacesAndNewlines))",
                    filePath: finding.context.lockfile,
                    lineNumber: finding.context.pin.line))
                return
            }

            var message = AdvisoryMessages.vulnerable(finding)
            if case .rejected(let why) = decision {
                message += " (the acknowledgement in `dependencyAudit.acknowledgedAdvisories` was not accepted: \(why))"
            }
            diagnostics.append(Diagnostic(
                severity: AdvisorySeverity.severity(forLabel: finding.candidate.advisory.severityLabel),
                message: message,
                filePath: finding.context.lockfile,
                lineNumber: finding.context.pin.line,
                ruleId: ruleId,
                suggestedFix: AdvisoryMessages.fix(finding)))
        }

        mutating func reportAcknowledgements() {
            diagnostics.append(contentsOf: acknowledgements.expiredDiagnostics())
            diagnostics.append(contentsOf: acknowledgements.unusedDiagnostics())
        }

        // MARK: Coverage

        /// The denominators, and the snapshot they were measured against.
        ///
        /// A run that examined zero lockfiles, or whose snapshot names none of the pinned
        /// packages, has said nothing; this is the line that lets a reader tell.
        func coverageNote(_ chosen: (snapshot: AdvisorySnapshot, origin: SnapshotOrigin)?) -> Diagnostic {
            var parts = [
                "dependency-advisory examined \(AdvisoryAudit.plural(tally.lockfiles, "lockfile"))",
                AdvisoryAudit.plural(tally.pins, "pin"),
                "\(tally.thirdPartyPins) third-party",
                "\(tally.evaluablePins) evaluable by version",
                "\(tally.unevaluablePins) unevaluable",
                "\(tally.affectedPins) affected by \(AdvisoryAudit.plural(tally.advisories.count, "advisory", "advisories"))",
                "\(tally.acknowledged) acknowledged",
            ]
            if let chosen {
                let packages = AdvisoryAudit.packages(in: chosen.snapshot)
                parts.append(
                    "snapshot \(chosen.snapshot.source)/\(Advisory.swiftEcosystem) fetched \(chosen.snapshot.fetched) "
                        + "(\(AdvisoryAudit.plural(chosen.snapshot.recordCount, "record")), "
                        + "\(tally.withdrawnRecords) withdrawn, \(AdvisoryAudit.plural(packages.count, "package")); "
                        + "\(chosen.origin.rawValue))")
            } else {
                parts.append("\(tally.notChecked) not checked")
                parts.append("snapshot none")
            }
            return Diagnostic(
                severity: .note, message: parts.joined(separator: " · "), ruleId: AdvisoryRule.coverage)
        }
    }

    /// One pin, with where it is and when the advisory data is from.
    struct PinContext {
        let pin: LockfilePin
        let lockfile: String
        let fetched: String

        /// The pin's location as `host/path`, in the lockfile's own case.
        var identity: String { AdvisoryMatcher.identity(ofLocation: pin.location) }
    }

    /// An advisory that names the pin's package, and how.
    struct Candidate {
        let advisory: Advisory
        let kind: AdvisoryMatcher.MatchKind
        let entries: [Advisory.Affected]

        /// Fails when no Swift entry of `advisory` names `pinIdentity`.
        init?(advisory: Advisory, pinIdentity: String) {
            var kinds: [AdvisoryMatcher.MatchKind] = []
            var entries: [Advisory.Affected] = []
            for entry in advisory.swiftAffected {
                guard let kind = AdvisoryMatcher.match(pinIdentity: pinIdentity, advisoryName: entry.name) else { continue }
                kinds.append(kind)
                entries.append(entry)
            }
            guard !entries.isEmpty else { return nil }
            self.advisory = advisory
            self.kind = kinds.contains(.url) ? .url : .name
            self.entries = entries
        }

        /// The package name the advisory used, for a by-name finding to quote.
        var advisoryName: String { entries.first?.name ?? "" }

        /// Affected if any entry says so; unevaluable if none does and one could not be read.
        func verdict(for version: AdvisoryVersion, text: String) -> AdvisoryMatcher.Verdict {
            var unevaluable: AdvisoryMatcher.Verdict?
            for entry in entries {
                switch AdvisoryMatcher.evaluate(version, text: text, against: entry) {
                case .affected(let hit): return .affected(hit)
                case .unevaluable(let bound): unevaluable = unevaluable ?? .unevaluable(bound: bound)
                case .clear: continue
                }
            }
            return unevaluable ?? .clear
        }
    }

    /// One pin an advisory reaches.
    struct Finding {
        let context: PinContext
        let candidate: Candidate
        let hit: AdvisoryMatcher.Hit
    }
}
