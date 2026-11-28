import Foundation
import QualityGateCore
import Testing
@testable import ReleaseReadinessAuditor

@Suite("Soak sealer")
struct SoakSealerTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func git(_ args: [String], in dir: URL) throws {
        let out = try ProcessRunner.run(
            "/usr/bin/git", arguments: ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args,
            environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path])
        #expect(out.exitCode == 0, "git \(args) failed: \(out.stderr)")
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soak-seal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "// a\n".write(to: dir.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try "// tools\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "first"], in: dir)
        return dir
    }

    private func parsed(
        minutes: Double = 100, footprint: (Double) -> Double = { 20 + sin($0) * 0.01 }, architecture: String? = "x86_64"
    ) -> SoakSamplesFile.Parsed {
        let samples = stride(from: 22.0, to: minutes * 60, by: 30).map {
            SoakSample(t: $0, footprintMB: footprint($0 / 60), descriptors: 12)
        }
        return SoakSamplesFile.Parsed(samples: samples, architecture: architecture)
    }

    private func seal(
        _ dir: URL, _ samples: SoakSamplesFile.Parsed, soak: SoakConfig = .default,
        drain: SoakDrain? = SoakDrain(exitCode: 0, seconds: 3)
    ) throws -> SoakResult {
        try SoakSealer.seal(
            repository: dir.path, samples: samples, soak: soak, package: "Demo", host: "Chromedome", toolchain: "Swift 6.4.2",
            endedAt: now, drain: drain, reloaded: true)
    }

    @Test("a sound run in a clean repository is sealed over the digest of its source, and judged")
    func sealsSoundRun() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try seal(dir, parsed())
        #expect(result.sourceDigest == SoakSourceDigest.digest(repository: dir.path, sources: SoakConfig.default.sources))
        #expect(result.package == "Demo")
        #expect(result.architecture == "x86_64")
        #expect(result.intervalSeconds == 30)
        #expect(result.durationSeconds == 5992)
        #expect(result.endedAt == now)
        #expect(result.startedAt == now.addingTimeInterval(-5992))
        #expect(result.sealed.verdict == .pass)
        #expect(result.drain == SoakDrain(exitCode: 0, seconds: 3))
        #expect(result.reloaded)
        #expect(result.schemaVersion == SoakResult.currentSchemaVersion)
    }

    @Test("a soak that grew is still sealed, so the release can say why it is blocked")
    func sealsFailure() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try seal(dir, parsed(footprint: { 20 + 4 * $0 / 60 }))
        if case .fail(let reasons) = result.sealed.verdict {
            #expect(reasons.count == 1)
            #expect(reasons.first?.contains("footprint") == true)
        } else {
            Issue.record("expected a recorded failure, got \(result.sealed.verdict)")
        }
        #expect(abs(try #require(result.sealed.slopeMBPerHour) - 4) < 0.01)
    }

    @Test("a tree with uncommitted changes to the soaked source is refused, naming the files")
    func refusesDirtyTree() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "// edited\n".write(to: dir.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        #expect(throws: SoakSealer.Refusal.uncommittedChanges(["Sources/A.swift"])) { try seal(dir, parsed()) }
    }

    @Test("sources that match no committed file are refused")
    func refusesNoSource() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let soak = try SoakConfig(sources: ["Nowhere/**"])
        #expect(throws: SoakSealer.Refusal.noSourceDigest) { try seal(dir, parsed(), soak: soak) }
    }

    @Test("a directory that is not a repository is refused, not guessed at")
    func refusesNonRepository() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soak-not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SoakSealer.Refusal.gitUnavailable) { try seal(dir, parsed()) }
    }

    @Test("fewer than two samples, or a negative time, cannot be sealed")
    func refusesUnusableSamples() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SoakSealer.Refusal.tooFewSamples) {
            try seal(dir, SoakSamplesFile.Parsed(samples: [SoakSample(t: 1, footprintMB: 1, descriptors: 1)], architecture: nil))
        }
        let negative = SoakSamplesFile.Parsed(
            samples: [SoakSample(t: -5, footprintMB: 1, descriptors: 1), SoakSample(t: 30, footprintMB: 1, descriptors: 1)], architecture: nil)
        #expect(throws: SoakSealer.Refusal.badSamples("a sample time is negative")) { try seal(dir, negative) }
        let huge = SoakSamplesFile.Parsed(
            samples: [SoakSample(t: 0, footprintMB: 1, descriptors: 1), SoakSample(t: 1e300, footprintMB: 1, descriptors: 1)], architecture: nil)
        #expect(throws: SoakSealer.Refusal.badSamples("a sample time is too large to be a duration")) { try seal(dir, huge) }
    }

    @Test("a written result reads back unchanged, and creates the .soak directory")
    func writeAndRead() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try seal(dir, parsed())
        try SoakSealer.write(result, repository: dir.path)
        let data = try Data(contentsOf: dir.appendingPathComponent(SoakResult.path))
        #expect(try SoakResult.decoder().decode(SoakResult.self, from: data) == result)
    }

    @Test("what the sealer writes is what the release path accepts: sealed, tagged, checked, clean")
    func endToEnd() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let soak = try SoakConfig(requiredFor: ["minor"])
        try SoakSealer.write(try seal(dir, parsed(), soak: soak), repository: dir.path)
        try git(["tag", "-a", "v2.1.0", "-m", "v2.1.0"], in: dir)
        let report = SoakReleaseCheck.evaluate(repository: dir.path, tag: "v2.1.0", soak: soak, now: now)
        #expect(report.findings.isEmpty)
    }
}
