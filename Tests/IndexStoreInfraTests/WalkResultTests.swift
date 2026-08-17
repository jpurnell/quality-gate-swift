import Foundation
import QualityGateCore
import Testing
@testable import IndexStoreInfra

/// A run should say how much of the tree it read.
///
/// Twice in one day a number that existed went unprinted and a reader drew the wrong conclusion.
/// `process-safety` passed for months while six deadlocks sat in directories its walk was never
/// pointed at — the silence read as "subprocesses here cannot hang". Then the git-ignore change
/// read as inert because the file count stayed at 640, two independent changes having cancelled
/// exactly. In both cases the scope was known and discarded.
@Suite("SourceWalker — stating what was left out")
struct WalkResultTests {

    private func makeRepo() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qg-walkresult-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ args: [String], in root: URL) throws {
        _ = try ProcessRunner.run("/usr/bin/git", arguments: args, currentDirectory: root.path, timeout: 30)
    }

    /// The common case stays quiet. A clause that always appears stops being read.
    @Test("a walk that read everything says nothing about exclusions")
    func fullWalkHasNoClause() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("func a() {}", to: root.appendingPathComponent("Sources/A.swift"))

        let result = SourceWalker.walk(under: root)
        #expect(result.files.count == 1)
        #expect(result.exclusionClause == nil, "nothing was excluded, so there is nothing to say")
    }

    @Test("config exclusions are counted and named")
    func patternExclusionsAreCounted() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("func a() {}", to: root.appendingPathComponent("Sources/A.swift"))
        try write("func b() {}", to: root.appendingPathComponent("Sources/Generated/B.swift"))

        let result = SourceWalker.walk(under: root, excludePatterns: ["Generated"])
        #expect(result.files.count == 1)
        #expect(result.excludedByPattern == 1)
        #expect(result.exclusionClause?.contains("1 excluded by config") == true)
    }

    /// A wholly ignored tree is reported as one directory, not as the files inside it.
    ///
    /// Descending purely to count would mean enumerating `.build`, which is the largest thing on
    /// disk and the whole reason the skip exists. A coarse honest number beats an expensive one.
    @Test("an ignored directory is reported as a directory")
    func ignoredDirectoryIsCountedOnce() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)
        try write("/vendored/\n", to: root.appendingPathComponent(".gitignore"))
        try write("func a() {}", to: root.appendingPathComponent("Sources/A.swift"))
        try write("func x() {}", to: root.appendingPathComponent("vendored/X.swift"))
        try write("func y() {}", to: root.appendingPathComponent("vendored/Y.swift"))

        let result = SourceWalker.walk(under: root)
        #expect(result.files.count == 1)
        #expect(result.gitIgnoredDirectories == 1, "one directory, not the two files within it")
        #expect(result.exclusionClause?.contains("1 git-ignored directory") == true)
    }

    /// **Attribution, and why the order of the checks matters.**
    ///
    /// `Pods` is both in the default skip list and, in almost every repository, git-ignored. Were
    /// the ignore check first, such directories would be reported as a git-ignored count that
    /// says nothing about the scope decision this reporting exists to expose — and a number
    /// nobody reads is worse than no number.
    ///
    /// A non-hidden directory is essential to this test. The first version used `.build`, which
    /// proved vacuous: the enumerator runs with `.skipsHiddenFiles`, so a dot-directory is never
    /// visited by either branch and the count is zero whichever order the checks are in. The test
    /// passed against a deliberately reversed implementation, which is how the hole was found.
    @Test("conventionally-skipped directories are not charged to git-ignore")
    func conventionalSkipsAreNotCountedAsIgnored() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)
        try write("Pods/\n", to: root.appendingPathComponent(".gitignore"))
        try write("func a() {}", to: root.appendingPathComponent("Sources/A.swift"))
        try write("func dep() {}", to: root.appendingPathComponent("Pods/Dep.swift"))

        let result = SourceWalker.walk(under: root)
        #expect(result.files.count == 1, "Pods is skipped either way")
        #expect(result.gitIgnoredDirectories == 0,
                "a conventional skip must not inflate the git-ignored count")
        #expect(result.exclusionClause == nil)
    }

    /// The wrapper the other 13 call sites use must keep behaving exactly as before.
    @Test("swiftFiles still returns just the paths")
    func wrapperIsUnchanged() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("func a() {}", to: root.appendingPathComponent("Sources/A.swift"))

        #expect(SourceWalker.swiftFiles(under: root) == SourceWalker.walk(under: root).files)
    }
}
