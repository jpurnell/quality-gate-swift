import Foundation
import Testing
import QualityGateCore
@testable import DependencyAdvisory

/// What the snapshot is missing, asked of the live database.
///
/// `.external`: it reaches the network, so by default it can only report notes, and when the
/// network is not there it is **skipped with the reason and the count of pins it did not check**
/// — not passed, not failed. No test here touches the network; the transport is injected, and
/// the responses that matter are the ones recorded from OSV on 2026-10-06.
@Suite("dependency-advisory-drift")
struct AdvisoryDriftTests {

    private typealias Pin = AdvisoryFixture.Pin

    private func project(_ pins: [Pin]) throws -> AdvisoryTestProject {
        let project = try AdvisoryTestProject()
        try project.write(AdvisoryFixture.lockfileText(pins), to: "Package.resolved")
        return project
    }

    private static let nioAndZip: [Pin] = [
        .version("swift-nio", "https://github.com/apple/swift-nio.git", "2.86.0"),
        .version("zip", "https://github.com/marmelroy/Zip.git", "2.1.2"),
    ]

    /// Answers a querybatch body from the recorded exchange, query by query.
    private static func recordedTransport() throws -> RecordingTransport {
        let exchanges = try RecordedOSV.exchanges()
        return RecordingTransport { request in
            struct Body: Decodable {
                struct Query: Decodable {
                    struct Package: Decodable { let name: String; let ecosystem: String }
                    let package: Package
                    let version: String
                }
                let queries: [Query]
            }
            let body = try JSONDecoder().decode(Body.self, from: request.body ?? Data())
            let results = body.queries.map { query -> String in
                let ids = exchanges.first { $0.name == query.package.name && $0.version == query.version }?.ids ?? []
                return ids.isEmpty ? "{}" : #"{"vulns":[\#(ids.map { #"{"id":"\#($0)","modified":"2026-09-10T03:51:08Z"}"# }.joined(separator: ","))]}"#
            }
            return Data(#"{"results":[\#(results.joined(separator: ","))]}"#.utf8)
        }
    }

    private func run(
        _ project: AdvisoryTestProject, environment: AdvisoryEnvironment,
        configuration: DependencyAuditorConfig = .default, includeNonHermetic: Bool = false
    ) async throws -> CheckResult {
        let results = await CheckerRunner().run(
            checkers: [AdvisoryDriftChecker(environment: environment)],
            configuration: project.configuration(configuration),
            strict: false, continueOnFailure: true, includeNonHermetic: includeNonHermetic).results
        return try #require(results.first)
    }

    // MARK: - Offline

    @Test("30. when the network is not there the checker is skipped, with the reason and the count it did not check")
    func transportErrorIsSkipped() async throws {
        let project = try project(Self.nioAndZip)
        defer { project.remove() }
        let environment = AdvisoryEnvironment.fixed(
            bundled: try RecordedOSV.candidate(), transport: RecordingTransport { _ in throw OfflineError() })

        let result = try await run(project, environment: environment)

        #expect(result.status == .skipped)
        #expect(result.diagnostics == [
            Diagnostic(
                severity: .note,
                message: "Skipped — external state unavailable: live OSV was not reached (The Internet connection "
                    + "appears to be offline.); 2 pins in 1 lockfile were not checked against the live database",
                ruleId: "hermeticity.external-unavailable"),
        ])
    }

    @Test("the checker itself throws on a transport error — it does not turn an unreachable server into a pass")
    func transportErrorThrows() async throws {
        let project = try project(Self.nioAndZip)
        defer { project.remove() }
        let checker = AdvisoryDriftChecker(environment: .fixed(
            bundled: try RecordedOSV.candidate(), transport: RecordingTransport { _ in throw OfflineError() }))
        await #expect(throws: AdvisoryUnavailable.self) {
            _ = try await checker.check(configuration: project.configuration())
        }
    }

    /// The one configuration under which a network failure fails a build: the caller asked for
    /// non-hermetic checkers to gate.
    @Test("with --include-nonhermetic an unreachable server is a failure, because the caller asked for that")
    func transportErrorFailsWhenAskedTo() async throws {
        let project = try project(Self.nioAndZip)
        defer { project.remove() }
        let environment = AdvisoryEnvironment.fixed(
            bundled: try RecordedOSV.candidate(), transport: RecordingTransport { _ in throw OfflineError() })
        let result = try await run(project, environment: environment, includeNonHermetic: true)
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["checker-error"])
    }

    @Test("offline mode skips without attempting a connection, and still says what was not checked")
    func offlineMode() async throws {
        let project = try project(Self.nioAndZip)
        defer { project.remove() }
        let transport = RecordingTransport { _ in Data() }
        let environment = AdvisoryEnvironment.fixed(bundled: try RecordedOSV.candidate(), transport: transport)

        let result = try await run(
            project, environment: environment,
            configuration: DependencyAuditorConfig(offlineMode: true), includeNonHermetic: true)

        #expect(result.status == .skipped)
        #expect(result.diagnostics == [
            Diagnostic(
                severity: .note,
                message: "Not checked: `dependencyAudit.offlineMode` is set, so live OSV was not queried. "
                    + "2 pins in 1 lockfile were not checked against the live database.",
                ruleId: "dep-advisory.drift-coverage"),
        ])
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - Drift

    /// The snapshot holds everything recorded except GHSA-rj37-6j9x-74q6, as if it had been
    /// fetched the day before that advisory was published.
    private func snapshotLackingOne() throws -> SnapshotCandidate {
        let records = try RecordedOSV.records().filter { $0["id"]?.stringValue != "GHSA-rj37-6j9x-74q6" }
        return SnapshotCandidate(
            origin: .bundled, path: "(recorded)",
            data: try AdvisorySnapshot.make(records: records, fetched: "2026-06-11").encoded())
    }

    private static let unlisted = "Live OSV lists GHSA-rj37-6j9x-74q6 for swift-nio 2.86.0 "
        + "(github.com/apple/swift-nio), and the advisory snapshot in use (bundled, fetched 2026-06-11) does not "
        + "hold it. `dependency-advisory` cannot report what its snapshot lacks — run "
        + "`quality-gate advisories refresh`. Queried 2026-10-06."

    private static let coverage = "dependency-advisory-drift queried api.osv.dev on 2026-10-06 · 2 pins · "
        + "2 distinct package versions queried · 0 not queried · 1 advisory the snapshot lacks · snapshot fetched "
        + "2026-06-11 (bundled)"

    @Test("31. an advisory the live database has and the snapshot lacks is reported as a note")
    func unlistedIsANote() async throws {
        let project = try project(Self.nioAndZip)
        defer { project.remove() }
        let environment = AdvisoryEnvironment.fixed(
            bundled: try snapshotLackingOne(), transport: try Self.recordedTransport())

        let result = try await run(project, environment: environment)

        #expect(result.status == .passed)
        #expect(result.diagnostics == [
            Diagnostic(
                severity: .note, message: Self.unlisted, filePath: "Package.resolved", lineNumber: 7,
                ruleId: "dep-advisory.unlisted"),
            Diagnostic(severity: .note, message: Self.coverage, ruleId: "dep-advisory.drift-coverage"),
        ])
    }

    @Test("31. …and with --include-nonhermetic it is an error")
    func unlistedFailsWhenAskedTo() async throws {
        let project = try project(Self.nioAndZip)
        defer { project.remove() }
        let environment = AdvisoryEnvironment.fixed(
            bundled: try snapshotLackingOne(), transport: try Self.recordedTransport())

        let result = try await run(project, environment: environment, includeNonHermetic: true)

        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.severity) == [.error, .note])
        #expect(result.diagnostics.first?.message == Self.unlisted)
    }

    @Test("a snapshot that already holds everything the live database returned has nothing to add")
    func noDrift() async throws {
        let project = try project(Self.nioAndZip)
        defer { project.remove() }
        let environment = AdvisoryEnvironment.fixed(
            bundled: try RecordedOSV.candidate(), transport: try Self.recordedTransport())

        let result = try await run(project, environment: environment, includeNonHermetic: true)

        #expect(result.status == .passed)
        #expect(result.diagnostics.map(\.message) == [
            "dependency-advisory-drift queried api.osv.dev on 2026-10-06 · 2 pins · 2 distinct package versions queried · "
                + "0 not queried · 0 advisories the snapshot lacks · snapshot fetched 2026-10-06 (bundled)",
        ])
    }

    // MARK: - The request

    @Test("one bounded POST carries every pin as a SwiftURL query, named the way OSV files the package")
    func requestShape() async throws {
        // `zip` lower-cased in the lockfile; the snapshot knows the package as `…/Zip`, and the
        // live API matches case-sensitively, so the query has to use the snapshot's spelling.
        let project = try project([
            .version("swift-nio", "git@github.com:apple/swift-nio.git", "2.86.0"),
            .version("zip", "https://github.com/marmelroy/zip.git", "2.1.2"),
            .version("swift-syntax", "https://github.com/swiftlang/swift-syntax.git", "600.0.1"),
            .branch("indexstore-db", "https://github.com/apple/indexstore-db.git", "main"),
        ])
        defer { project.remove() }
        let transport = try Self.recordedTransport()

        let result = try await run(
            project, environment: .fixed(bundled: try RecordedOSV.candidate(), transport: transport))

        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url.absoluteString == "https://api.osv.dev/v1/querybatch")
        #expect(request.timeoutSeconds == 10)
        #expect(request.maximumResponseBytes == 2 * 1024 * 1024)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"queries": [
          {"package": {"ecosystem": "SwiftURL", "name": "github.com/apple/swift-nio"}, "version": "2.86.0"},
          {"package": {"ecosystem": "SwiftURL", "name": "github.com/marmelroy/Zip"}, "version": "2.1.2"},
          {"package": {"ecosystem": "SwiftURL", "name": "github.com/swiftlang/swift-syntax"}, "version": "600.0.1"}
        ]}
        """.utf8))
        #expect(body == expected)
        #expect(result.diagnostics.last?.message == "dependency-advisory-drift queried api.osv.dev on 2026-10-06 · "
            + "4 pins · 3 distinct package versions queried · 1 not queried (1 without a version) · "
            + "0 advisories the snapshot lacks · snapshot fetched 2026-10-06 (bundled)")
    }

    @Test("queries beyond the cap are not sent, and are counted as not queried")
    func cap() async throws {
        let project = try project((1...5).map {
            .version("pkg\($0)", "https://github.com/example/pkg\($0).git", "1.0.\($0)")
        })
        defer { project.remove() }
        let transport = RecordingTransport { request in
            let count = (try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data()))["queries"]?.arrayValue.count ?? 0
            return Data(#"{"results":[\#(Array(repeating: "{}", count: count).joined(separator: ","))]}"#.utf8)
        }
        let checker = AdvisoryDriftChecker(
            environment: .fixed(bundled: try RecordedOSV.candidate(), transport: transport),
            limits: OSVQueryBatch.Limits(queriesPerBatch: 2, batches: 2))

        let result = try await checker.check(configuration: project.configuration())

        #expect(await transport.requests.count == 2)
        #expect(result.diagnostics.last?.message == "dependency-advisory-drift queried api.osv.dev on 2026-10-06 · "
            + "5 pins · 4 distinct package versions queried · 1 not queried (1 over the 4-query cap) · "
            + "0 advisories the snapshot lacks · snapshot fetched 2026-10-06 (bundled)")
    }

    @Test("the production limits are the documented ones")
    func productionLimits() {
        #expect(OSVQueryBatch.Limits.standard == OSVQueryBatch.Limits(queriesPerBatch: 500, batches: 4))
        #expect(OSVQueryBatch.timeoutSeconds == 10)
        #expect(OSVQueryBatch.maximumResponseBytes == 2 * 1024 * 1024)
    }

    // MARK: - The response

    @Test("the recorded response parses to the ids OSV returned, in query order")
    func parsesRecordedResponse() throws {
        let answers = try OSVQueryBatch.parse(try RecordedOSV.data("querybatch-response.json"), expecting: 11)
        #expect(answers.map(\.ids.count) == [3, 0, 5, 1, 0, 1, 0, 7, 1, 0, 1])
        #expect(answers[0].ids == ["GHSA-cq87-8r7h-962v", "GHSA-r3rc-9hpw-54v9", "GHSA-rj37-6j9x-74q6"])
        #expect(answers.allSatisfy { !$0.truncated })
    }

    @Test("a response that does not answer every query is not read as clean", arguments: [
        #"{"results":[{}]}"#, #"{"results":"none"}"#, "<html>502 Bad Gateway</html>", "",
    ])
    func malformedResponse(body: String) async throws {
        let project = try project(Self.nioAndZip)
        defer { project.remove() }
        let checker = AdvisoryDriftChecker(environment: .fixed(
            bundled: try RecordedOSV.candidate(), transport: RecordingTransport { _ in Data(body.utf8) }))
        await #expect(throws: AdvisoryUnavailable.self) {
            _ = try await checker.check(configuration: project.configuration())
        }
    }

    @Test("a paginated answer is counted as incomplete rather than taken as the whole list")
    func truncatedAnswer() throws {
        let answers = try OSVQueryBatch.parse(
            Data(#"{"results":[{"vulns":[{"id":"GHSA-a"}],"next_page_token":"abc"}]}"#.utf8), expecting: 1)
        #expect(answers == [OSVQueryBatch.Answer(ids: ["GHSA-a"], truncated: true)])
    }

    @Test("a project with no lockfile is skipped")
    func noLockfile() async throws {
        let project = try AdvisoryTestProject()
        defer { project.remove() }
        let result = try await AdvisoryDriftChecker(environment: .fixed(bundled: try RecordedOSV.candidate()))
            .check(configuration: project.configuration())
        #expect(result.status == .skipped)
        #expect(result.diagnostics.map(\.message) == [
            "No Package.resolved was found under the project root, so there are no pins to check against the live database.",
        ])
    }
}
