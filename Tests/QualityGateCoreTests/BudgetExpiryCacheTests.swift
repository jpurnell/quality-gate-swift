import Foundation
import Testing
@testable import QualityGateCore

// A run that was stopped at its budget has no verdict, so there is nothing to replay.
//
// The runner already refuses to store a failure. That guard reads the status the checker
// reported — and the misreport that started all this was a cut-off `swift test` returned as
// `.passed` with a signing warning, which the cache stored and then served, dated and
// labelled "replayed", to every later run of the same tree. The guard has to hold whatever
// status the checker chose: it is judged on the result as the run will report it, and an
// expiry is never stored at all.

/// A checker that reports whatever it is told to, and counts how often it actually ran.
private struct ScriptedChecker: QualityChecker {
    let id = "scripted"
    let name = "scripted"
    let summary = "Test double; not a documented checker"
    let category = CheckerCategory.specialty
    let kind = CheckerKind.code
    let effect = CheckerEffect.readOnly
    let executesProjectCode = false
    let inputs: [String]
    let status: CheckResult.Status
    let diagnostics: [Diagnostic]
    let runs: RunCount

    func cacheInputs(configuration: Configuration) -> CacheInputs? { CacheInputs(files: inputs) }

    func check(configuration: Configuration) async throws -> CheckResult {
        await runs.increment()
        return CheckResult(checkerId: id, status: status, diagnostics: diagnostics, duration: .zero)
    }
}

private actor RunCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite("A run stopped at its budget is never replayed")
struct BudgetExpiryCacheTests {

    private static let expiry = Diagnostic(
        severity: .error, message: "stopped at its time budget", ruleId: "test-timeout")

    private struct Fixture {
        let input: URL
        let cache: ResultCache
        let fingerprint: String
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-expiry-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        return Fixture(
            input: input,
            cache: ResultCache(directory: directory.appendingPathComponent("cache")),
            fingerprint: CheckerFingerprint.compute(
                checkerId: "scripted", inputs: CacheInputs(files: [input.path]), gateHash: "gate"))
    }

    private func run(_ checker: ScriptedChecker, cache: ResultCache) async -> CheckResult? {
        await CheckerRunner(maxConcurrency: 1).run(
            checkers: [checker], configuration: Configuration(),
            strict: false, continueOnFailure: true,
            cache: cache, gateHash: "gate", useCache: true
        ).results.first
    }

    @Test("An expiry reported under a passing status is not stored, and the next run runs")
    func expiryUnderAPassingStatusIsNotStored() async throws {
        let fixture = try fixture()
        let runs = RunCount()
        let cutOff = ScriptedChecker(
            inputs: [fixture.input.path], status: .passed, diagnostics: [Self.expiry], runs: runs)

        let first = await run(cutOff, cache: fixture.cache)
        #expect(first?.status == .failed)
        #expect(fixture.cache.load(checkerId: "scripted", fingerprint: fixture.fingerprint) == nil)

        let second = await run(cutOff, cache: fixture.cache)
        #expect(await runs.value == 2)
        #expect(second?.diagnostics.map(\.ruleId) == ["test-timeout"])
    }

    @Test("An expiry downgraded to a warning is not stored either")
    func expiryAsAWarningIsNotStored() async throws {
        let fixture = try fixture()
        let warning = Diagnostic(
            severity: .warning, message: "stopped at its time budget", ruleId: "doc-lint-timeout")
        let cutOff = ScriptedChecker(
            inputs: [fixture.input.path], status: .warning, diagnostics: [warning], runs: RunCount())

        _ = await run(cutOff, cache: fixture.cache)
        #expect(fixture.cache.load(checkerId: "scripted", fingerprint: fixture.fingerprint) == nil)
    }

    @Test("An error carried under a passing status is not stored: the cache judges the reported verdict")
    func errorUnderAPassingStatusIsNotStored() async throws {
        let fixture = try fixture()
        let error = Diagnostic(severity: .error, message: "broken", ruleId: "fake.error")
        let runs = RunCount()
        let checker = ScriptedChecker(
            inputs: [fixture.input.path], status: .passed, diagnostics: [error], runs: runs)

        _ = await run(checker, cache: fixture.cache)
        _ = await run(checker, cache: fixture.cache)
        #expect(await runs.value == 2)
        #expect(fixture.cache.load(checkerId: "scripted", fingerprint: fixture.fingerprint) == nil)
    }

    @Test("An expiry already on disk under a passing status is evicted, not replayed")
    func storedExpiryIsEvicted() async throws {
        let fixture = try fixture()
        // As a gate from before this change left it: a cut-off run stored as a pass.
        fixture.cache.store(
            CheckResult(
                checkerId: "scripted", status: .passed,
                diagnostics: [Diagnostic(severity: .warning, message: "cut off", ruleId: "test-timeout")],
                duration: .zero),
            checkerId: "scripted", fingerprint: fixture.fingerprint)

        let runs = RunCount()
        let clean = ScriptedChecker(
            inputs: [fixture.input.path], status: .passed, diagnostics: [], runs: runs)
        let result = await run(clean, cache: fixture.cache)

        #expect(await runs.value == 1)
        #expect(result?.status == .passed)
        #expect(result?.diagnostics.isEmpty == true)
    }

    @Test("A finished, passing run is still stored and replayed")
    func finishedRunIsStillReplayed() async throws {
        let fixture = try fixture()
        let runs = RunCount()
        let clean = ScriptedChecker(
            inputs: [fixture.input.path], status: .passed, diagnostics: [], runs: runs)

        _ = await run(clean, cache: fixture.cache)
        let replayed = await run(clean, cache: fixture.cache)
        #expect(await runs.value == 1)
        #expect(replayed?.diagnostics.map(\.ruleId) == ["cache.replayed"])
    }
}
