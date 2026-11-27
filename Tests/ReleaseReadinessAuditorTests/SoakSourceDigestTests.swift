import Foundation
import QualityGateCore
import Testing
@testable import ReleaseReadinessAuditor

@Suite("Soak source globs")
struct SoakSourceGlobTests {

    @Test("`dir/**` matches anything beneath it at any depth, and nothing outside")
    func recursive() {
        #expect(SoakSourceDigest.matches("Sources/Kit/A.swift", pattern: "Sources/**"))
        #expect(SoakSourceDigest.matches("Sources/A.swift", pattern: "Sources/**"))
        #expect(SoakSourceDigest.matches("Sources/a/b/c/D.swift", pattern: "Sources/**"))
        #expect(!SoakSourceDigest.matches("Tests/KitTests/A.swift", pattern: "Sources/**"))
        #expect(!SoakSourceDigest.matches("Sources", pattern: "Sources/**"))
        #expect(!SoakSourceDigest.matches("SourcesExtra/A.swift", pattern: "Sources/**"))
    }

    @Test("a plain name matches only that path; `*` stays within one path segment")
    func plain() {
        #expect(SoakSourceDigest.matches("Package.swift", pattern: "Package.swift"))
        #expect(!SoakSourceDigest.matches("Sub/Package.swift", pattern: "Package.swift"))
        #expect(SoakSourceDigest.matches("Sources/Kit/A.swift", pattern: "Sources/*/A.swift"))
        #expect(!SoakSourceDigest.matches("Sources/a/b/A.swift", pattern: "Sources/*/A.swift"))
        #expect(SoakSourceDigest.matches("scripts/soak.sh", pattern: "scripts/soak.*"))
    }
}

@Suite("Soak source digest")
struct SoakSourceDigestTests {

    private let sources = ["Sources/**", "Package.swift", "Package.resolved"]
    private func file(_ path: String, _ blob: String) -> SoakSourceDigest.TrackedFile { .init(path: path, blobID: blob) }

    @Test("it is 64 hex characters, and the same for the same source in any order")
    func shape() throws {
        let a = [file("Sources/A.swift", "aaa"), file("Package.swift", "bbb")]
        let digest = try #require(SoakSourceDigest.digest(of: a, sources: sources))
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit })
        #expect(SoakSourceDigest.digest(of: a.reversed(), sources: sources) == digest)
    }

    @Test("a changed blob, a renamed file or an added source file changes it")
    func sensitive() throws {
        let base = [file("Sources/A.swift", "aaa"), file("Package.swift", "bbb")]
        let digest = try #require(SoakSourceDigest.digest(of: base, sources: sources))
        #expect(SoakSourceDigest.digest(of: [file("Sources/A.swift", "ccc"), file("Package.swift", "bbb")], sources: sources) != digest)
        #expect(SoakSourceDigest.digest(of: [file("Sources/B.swift", "aaa"), file("Package.swift", "bbb")], sources: sources) != digest)
        #expect(SoakSourceDigest.digest(of: base + [file("Sources/C.swift", "ddd")], sources: sources) != digest)
    }

    @Test("a file outside `sources`, such as the CHANGELOG, does not change it")
    func insensitive() throws {
        let base = [file("Sources/A.swift", "aaa"), file("Package.swift", "bbb")]
        let digest = try #require(SoakSourceDigest.digest(of: base, sources: sources))
        #expect(SoakSourceDigest.digest(of: base + [file("CHANGELOG.md", "zzz")], sources: sources) == digest)
    }

    @Test("path and blob cannot be confused with each other")
    func unambiguous() {
        let one = SoakSourceDigest.digest(of: [file("Sources/ab", "c")], sources: sources)
        let two = SoakSourceDigest.digest(of: [file("Sources/a", "bc")], sources: sources)
        #expect(one != two)
    }

    @Test("a configuration that matches no file has no digest, rather than a digest of nothing")
    func nothingMatches() {
        #expect(SoakSourceDigest.digest(of: [file("README.md", "aaa")], sources: sources) == nil)
        #expect(SoakSourceDigest.digest(of: [], sources: sources) == nil)
    }
}

@Suite("Soak source digest in a repository")
struct SoakSourceDigestRepositoryTests {

    private func git(_ args: [String], in dir: URL) throws {
        let out = try ProcessRunner.run(
            "/usr/bin/git", arguments: ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args,
            environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path])
        #expect(out.exitCode == 0, "git \(args) failed: \(out.stderr)")
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("soak-digest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "// a\n".write(to: dir.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.2\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "# Changes\n".write(to: dir.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "first"], in: dir)
        return dir
    }

    @Test("a release commit that only edits the CHANGELOG keeps the digest; a source change moves it")
    func stableAcrossChangelogCommit() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try #require(SoakSourceDigest.digest(repository: dir.path, sources: ["Sources/**", "Package.swift"]))

        try "# Changes\n## [1.0.0]\n".write(to: dir.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "release"], in: dir)
        #expect(SoakSourceDigest.digest(repository: dir.path, sources: ["Sources/**", "Package.swift"]) == before)

        try "// b\n".write(to: dir.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "code"], in: dir)
        #expect(SoakSourceDigest.digest(repository: dir.path, sources: ["Sources/**", "Package.swift"]) != before)
    }

    @Test("uncommitted changes to soaked source are listed; a CHANGELOG edit is not")
    func uncommitted() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = ["Sources/**", "Package.swift"]
        #expect(SoakSourceDigest.uncommittedChanges(repository: dir.path, sources: sources) == [])

        try "# edited\n".write(to: dir.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        #expect(SoakSourceDigest.uncommittedChanges(repository: dir.path, sources: sources) == [])

        try "// changed\n".write(to: dir.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
        try "// new\n".write(to: dir.appendingPathComponent("Sources/New.swift"), atomically: true, encoding: .utf8)
        #expect(SoakSourceDigest.uncommittedChanges(repository: dir.path, sources: sources) == ["Sources/A.swift", "Sources/New.swift"])
    }

    @Test("a directory that is not a repository has no digest")
    func notARepository() {
        #expect(SoakSourceDigest.digest(repository: FileManager.default.temporaryDirectory.path + "/definitely-not-a-repo-\(UUID().uuidString)", sources: ["Sources/**"]) == nil)
    }
}
