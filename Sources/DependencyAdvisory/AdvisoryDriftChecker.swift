import Foundation
import QualityGateCore
import QualityGateLogging

/// Asks live OSV what the snapshot is missing.
///
/// `dependency-advisory` can only report what its snapshot holds. This checker sends each pinned
/// package version to `https://api.osv.dev/v1/querybatch` and reports any advisory id that comes
/// back and is not in the snapshot — exactly what the hermetic check is missing, by name.
///
/// ## It never passes for want of an answer
///
/// It is `Hermeticity.external`. When the server cannot be reached it **throws**, and the
/// runner reports `.skipped` with the reason and the number of pins that were not checked — not
/// a pass, and not a failure: a build must not fail because the network is down. The one
/// exception is the one the caller asks for, `--include-nonhermetic`. With
/// `dependencyAudit.offlineMode` set it does not attempt a connection at all, and says so.
///
/// It is opt-in (`--check dependency-advisory-drift`): a network round trip belongs in a
/// scheduled job, not in every pre-commit hook.
///
/// ## Every call is bounded
///
/// One request per 500 distinct package versions, at most four requests, ten seconds each, and
/// two megabytes of response each. What exceeds the cap is counted as not queried, in the note.
///
/// ## What the live API cannot be asked
///
/// It matches names case-sensitively and by URL only, so it never returns the three records the
/// export files under a bare name. Those are in the snapshot, and the hermetic checker finds
/// them; this one cannot say whether there are more.
///
/// ## Rules
///
/// | Rule ID | What it reports | Severity |
/// |---|---|---|
/// | `dep-advisory.unlisted` | Live OSV names an advisory for a pin that the snapshot lacks | note; error under `--include-nonhermetic` |
/// | `dep-advisory.drift-coverage` | What was queried, when, and what was not | note |
public struct AdvisoryDriftChecker: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DependencyAdvisory")

    /// Unique identifier for this checker.
    public let id = "dependency-advisory-drift"

    /// Human-readable name for display.
    public let name = "Dependency Advisory Drift"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Advisories live OSV lists for a pinned version that the snapshot lacks; skipped, with the count of pins not checked, when OSV is unreachable (opt-in, never gates by default)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.safetySecurity

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Reads lockfiles and queries a server; runs nothing.
    public let executesProjectCode = false

    /// Depends on a server answering, so it is clamped to notes and a throw becomes `.skipped`.
    public var hermeticity: Hermeticity { .external }

    let environment: AdvisoryEnvironment
    let limits: OSVQueryBatch.Limits

    /// Creates the checker.
    public init() {
        self.init(environment: .live)
    }

    init(environment: AdvisoryEnvironment, limits: OSVQueryBatch.Limits = .standard) {
        self.environment = environment
        self.limits = limits
    }

    /// One pin as it will be asked about.
    private struct Asked {
        let pin: LockfilePin
        let lockfile: String
        let identity: String
        let query: OSVQueryBatch.Query?
    }

    /// Queries live OSV for every versioned pin and reports ids the snapshot does not hold.
    ///
    /// - Parameter configuration: Supplies the project root and the `dependencyAudit` block.
    /// - Returns: Unlisted advisories and a coverage note; `.skipped` with no lockfile or in
    ///   offline mode.
    /// - Throws: `AdvisoryUnavailable` when OSV cannot be reached or does not answer in the
    ///   documented shape, carrying the number of pins left unchecked.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        let lockfiles = LockfileDiscovery.discover(under: root).lockfiles
        let pinCount = lockfiles.reduce(0) { $0 + $1.pins.count }
        let unchecked = "\(AdvisoryAudit.plural(pinCount, "pin")) in \(AdvisoryAudit.plural(lockfiles.count, "lockfile")) "
            + "\(pinCount == 1 ? "was" : "were") not checked against the live database"

        guard !lockfiles.isEmpty else {
            return skipped(
                "No Package.resolved was found under the project root, so there are no pins to check against "
                    + "the live database.", since: start)
        }
        guard !configuration.dependencyAudit.offlineMode else {
            return skipped(
                "Not checked: `dependencyAudit.offlineMode` is set, so live OSV was not queried. \(unchecked).",
                since: start)
        }

        let chosen = environment.snapshot(projectRoot: root, configuration: configuration.dependencyAudit)
        let asked = Self.asked(lockfiles, snapshot: chosen?.snapshot)
        let sent = Array(Self.distinctQueries(asked).prefix(limits.total))

        let answers: [OSVQueryBatch.Query: OSVQueryBatch.Answer]
        do {
            answers = try await ask(sent)
        } catch let unavailable as AdvisoryUnavailable {
            throw AdvisoryUnavailable(reason: "\(unavailable.reason); \(unchecked)")
        } catch {
            Self.logger.warning("live OSV was not reached: \(error.localizedDescription, privacy: .public)")
            throw AdvisoryUnavailable(reason: "live OSV was not reached (\(error.localizedDescription)); \(unchecked)")
        }

        let exchange = Exchange(
            asked: asked, sent: sent.count, answers: answers,
            today: AdvisoryDate(utcDateOf: environment.now()).text, chosen: chosen)
        let unlisted = unlistedFindings(exchange)
        return CheckResult(
            checkerId: id,
            status: unlisted.isEmpty ? .passed : .failed,
            diagnostics: unlisted.map(\.diagnostic) + [
                Diagnostic(
                    severity: .note,
                    message: coverage(exchange, unlisted: Set(unlisted.map(\.advisory)).count),
                    ruleId: AdvisoryRule.driftCoverage),
            ],
            duration: ContinuousClock.now - start)
    }

    /// One run's questions and answers.
    private struct Exchange {
        let asked: [Asked]
        let sent: Int
        let answers: [OSVQueryBatch.Query: OSVQueryBatch.Answer]
        let today: String
        let chosen: (snapshot: AdvisorySnapshot, origin: SnapshotOrigin)?
    }

    /// One finding per pin per advisory that live OSV returned and the snapshot does not hold.
    ///
    /// Errors here, which the runner's clamp reports as notes unless `--include-nonhermetic`.
    private func unlistedFindings(_ exchange: Exchange) -> [(advisory: String, diagnostic: Diagnostic)] {
        let known = Set(exchange.chosen?.snapshot.advisories.map(\.id) ?? [])
        let held = exchange.chosen.map {
            "the advisory snapshot in use (\($0.origin.rawValue), fetched \($0.snapshot.fetched)) does not hold it"
        } ?? "no advisory snapshot is in use to hold it"

        var findings: [(advisory: String, diagnostic: Diagnostic)] = []
        for item in exchange.asked {
            guard let query = item.query, let answer = exchange.answers[query] else { continue }
            for advisory in answer.ids where !known.contains(advisory) {
                findings.append((advisory, Diagnostic(
                    severity: .error,
                    message: "Live OSV lists \(advisory) for \(item.pin.identity) \(query.version) (\(item.identity)), "
                        + "and \(held). `dependency-advisory` cannot report what its snapshot lacks — run "
                        + "`quality-gate advisories refresh`. Queried \(exchange.today).",
                    filePath: item.lockfile,
                    lineNumber: item.pin.line,
                    ruleId: AdvisoryRule.unlisted)))
            }
        }
        return findings
    }

    // MARK: - Asking

    /// Every pin, with the query that will be made for it — or none, when it has no version.
    ///
    /// The name is the snapshot's spelling of the package when the snapshot knows it: the live
    /// API matches case-sensitively, and a lockfile that lower-cased `…/Zip` would otherwise be
    /// asked about a package OSV has never heard of.
    private static func asked(_ lockfiles: [Lockfile], snapshot: AdvisorySnapshot?) -> [Asked] {
        var filedAs: [String: String] = [:]
        for name in (snapshot?.advisories ?? []).flatMap(\.swiftAffected).map(\.name) where name.contains("/") {
            filedAs[name.lowercased()] = name
        }
        return lockfiles.flatMap { lockfile in
            lockfile.pins.map { pin -> Asked in
                let identity = AdvisoryMatcher.identity(ofLocation: pin.location)
                let query = pin.version
                    .flatMap { AdvisoryVersion($0) == nil ? nil : $0 }
                    .map { OSVQueryBatch.Query(name: filedAs[identity.lowercased()] ?? identity, version: $0) }
                return Asked(pin: pin, lockfile: lockfile.path, identity: identity, query: query)
            }
        }
    }

    /// The queries to make, each once, in first-seen order.
    private static func distinctQueries(_ asked: [Asked]) -> [OSVQueryBatch.Query] {
        var seen: Set<OSVQueryBatch.Query> = []
        return asked.compactMap(\.query).filter { seen.insert($0).inserted }
    }

    /// Sends `queries` in batches and pairs each with its answer.
    private func ask(_ queries: [OSVQueryBatch.Query]) async throws -> [OSVQueryBatch.Query: OSVQueryBatch.Answer] {
        let endpoint = try AdvisoryRequest.url(OSVQueryBatch.address)
        var answers: [OSVQueryBatch.Query: OSVQueryBatch.Answer] = [:]
        let size = max(1, limits.queriesPerBatch)
        for offset in stride(from: 0, to: queries.count, by: size) {
            let batch = Array(queries[offset..<min(offset + size, queries.count)])
            let data = try await environment.transport.send(AdvisoryRequest(
                url: endpoint,
                body: try OSVQueryBatch.body(for: batch),
                timeoutSeconds: OSVQueryBatch.timeoutSeconds,
                maximumResponseBytes: OSVQueryBatch.maximumResponseBytes))
            for (query, answer) in zip(batch, try OSVQueryBatch.parse(data, expecting: batch.count)) {
                answers[query] = answer
            }
        }
        return answers
    }

    // MARK: - Reporting

    /// What was asked, when, and what was not — the denominators for "0 advisories the snapshot lacks".
    private func coverage(_ exchange: Exchange, unlisted: Int) -> String {
        let unversioned = exchange.asked.filter { $0.query == nil }.count
        let overCap = exchange.asked.filter { item in item.query.map { exchange.answers[$0] == nil } ?? false }.count
        let truncated = exchange.answers.values.filter(\.truncated).count
        var reasons: [String] = []
        if unversioned > 0 { reasons.append("\(unversioned) without a version") }
        if overCap > 0 { reasons.append("\(overCap) over the \(limits.total)-query cap") }
        let notQueried = "\(unversioned + overCap) not queried"
            + (reasons.isEmpty ? "" : " (\(reasons.joined(separator: ", ")))")

        var parts = [
            "dependency-advisory-drift queried api.osv.dev on \(exchange.today)",
            AdvisoryAudit.plural(exchange.asked.count, "pin"),
            "\(AdvisoryAudit.plural(exchange.sent, "distinct package version")) queried",
            notQueried,
        ]
        if truncated > 0 { parts.append("\(truncated) answered incompletely (paginated)") }
        parts.append("\(AdvisoryAudit.plural(unlisted, "advisory", "advisories")) the snapshot lacks")
        parts.append(
            exchange.chosen.map { "snapshot fetched \($0.snapshot.fetched) (\($0.origin.rawValue))" } ?? "snapshot none")
        return parts.joined(separator: " · ")
    }

    private func skipped(_ message: String, since start: ContinuousClock.Instant) -> CheckResult {
        CheckResult(
            checkerId: id, status: .skipped,
            diagnostics: [Diagnostic(severity: .note, message: message, ruleId: AdvisoryRule.driftCoverage)],
            duration: ContinuousClock.now - start)
    }
}
