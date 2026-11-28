import Foundation
import QualityGateCore
import Testing
@testable import ReleaseReadinessAuditor

@Suite("Soak check at a release")
struct SoakReleaseCheckTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func git(_ args: [String], in dir: URL) throws {
        let out = try ProcessRunner.run(
            "/usr/bin/git", arguments: ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args,
            environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path])
        #expect(out.exitCode == 0, "git \(args) failed: \(out.stderr)")
    }

    /// A repository with source, a tag `v2.1.0` on it, and no soak result.
    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soak-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "// a\n".write(to: dir.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try "// tools\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "first"], in: dir)
        try git(["tag", "-a", "v2.1.0", "-m", "v2.1.0"], in: dir)
        return dir
    }

    private func writeResult(_ result: SoakResult, in dir: URL) throws {
        let folder = dir.appendingPathComponent(".soak")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SoakResult.encoder().encode(result).write(to: folder.appendingPathComponent("result.json"))
    }

    private func soundResult(digest: String) -> SoakResult {
        let s = stride(from: 22.0, to: 6000.0, by: 30).map { SoakSample(t: $0, footprintMB: 20 + sin($0) * 0.01, descriptors: 12) }
        return SoakResult(
            schemaVersion: SoakResult.currentSchemaVersion, package: "Demo", sourceDigest: digest,
            startedAt: now.addingTimeInterval(-90_000), endedAt: now.addingTimeInterval(-86_400), durationSeconds: 6000,
            host: "Chromedome", toolchain: "Swift 6.4.2", intervalSeconds: 30, architecture: "x86_64", samples: s,
            drain: SoakDrain(exitCode: 0, seconds: 3), reloaded: true,
            sealed: SoakJudgement.judge(samples: s, architecture: "x86_64", limits: .calibrated))
    }

    private func required() throws -> SoakConfig { try SoakConfig(requiredFor: ["minor"]) }

    @Test("a package that has not opted in hears nothing, even at a tag push")
    func silentWhenNotOptedIn() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = SoakReleaseCheck.evaluate(repository: dir.path, tag: "v2.1.0", soak: .default, now: now)
        #expect(report.findings.isEmpty)
        #expect(report.notes.isEmpty)
    }

    @Test("a required tag with no result file is soak-missing")
    func missing() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = SoakReleaseCheck.evaluate(repository: dir.path, tag: "v2.1.0", soak: try required(), now: now)
        #expect(report.findings.map(\.ruleId) == ["release.soak-missing"])
    }

    @Test("a sound result sealed over the tagged source raises nothing")
    func sound() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try required()
        let digest = try #require(SoakSourceDigest.digest(repository: dir.path, revision: "v2.1.0", sources: config.sources))
        try writeResult(soundResult(digest: digest), in: dir)
        let report = SoakReleaseCheck.evaluate(repository: dir.path, tag: "v2.1.0", soak: config, now: now)
        #expect(report.findings.isEmpty)
    }

    @Test("source changed after the soak makes it stale: the digest is of the tagged commit")
    func stale() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try required()
        let digest = try #require(SoakSourceDigest.digest(repository: dir.path, revision: "v2.1.0", sources: config.sources))
        try writeResult(soundResult(digest: digest), in: dir)
        try "// changed\n".write(to: dir.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "code"], in: dir)
        try git(["tag", "-a", "v2.2.0", "-m", "v2.2.0"], in: dir)
        let report = SoakReleaseCheck.evaluate(repository: dir.path, tag: "v2.2.0", soak: config, now: now)
        #expect(report.findings.map(\.ruleId) == ["release.soak-stale-source"])
    }

    @Test("a result file that cannot be read is unreadable, not missing")
    func unreadable() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".soak"), withIntermediateDirectories: true)
        try "{ not json".write(to: dir.appendingPathComponent(".soak/result.json"), atomically: true, encoding: .utf8)
        let report = SoakReleaseCheck.evaluate(repository: dir.path, tag: "v2.1.0", soak: try required(), now: now)
        #expect(report.findings.map(\.ruleId) == ["release.soak-unreadable"])
    }

    @Test("sources that match no committed file leave nothing to tie a soak to, and say so")
    func noDigest() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try SoakConfig(requiredFor: ["minor"], sources: ["Nowhere/**"])
        try writeResult(soundResult(digest: String(repeating: "a", count: 64)), in: dir)
        let report = SoakReleaseCheck.evaluate(repository: dir.path, tag: "v2.1.0", soak: config, now: now)
        #expect(report.findings.map(\.ruleId) == ["release.soak-no-digest"])
    }

    @Test("at a push, only a tag being published is checked: branches and deletions are ignored")
    func pushDiagnostics() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zero = String(repeating: "0", count: 40)
        let refs = try #require(PushedRefs.parse("""
        refs/heads/main aaaa111 refs/heads/main bbbb222
        refs/tags/v2.0.0 \(zero) refs/tags/v2.0.0 cccc333
        refs/tags/v2.1.0 dddd444 refs/tags/v2.1.0 \(zero)
        """))
        let diagnostics = SoakReleaseCheck.diagnostics(repository: dir.path, pushedRefs: refs, soak: try required(), now: now)
        #expect(diagnostics.map(\.ruleId) == ["release.soak-missing"])
        #expect(diagnostics.first?.severity == .error)
    }

    @Test("notes are reported as notes, and nothing is checked outside a push")
    func notesAndNoPush() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let waived = try SoakConfig(
            requiredFor: ["minor"], waiver: SoakConfig.Waiver(version: "2.1.0", reason: "docs only", date: "2026-12-01"))
        let refs = try #require(PushedRefs.parse("refs/tags/v2.1.0 dddd444 refs/tags/v2.1.0 \(String(repeating: "0", count: 40))"))
        let diagnostics = SoakReleaseCheck.diagnostics(repository: dir.path, pushedRefs: refs, soak: waived, now: now)
        #expect(diagnostics.map(\.ruleId) == ["release.soak-waived"])
        #expect(diagnostics.first?.severity == .note)
        #expect(SoakReleaseCheck.diagnostics(repository: dir.path, pushedRefs: nil, soak: try required(), now: now).isEmpty)
    }
}
