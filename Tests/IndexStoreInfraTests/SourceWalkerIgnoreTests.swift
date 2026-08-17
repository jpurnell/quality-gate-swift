import Foundation
import QualityGateCore
import Testing
@testable import IndexStoreInfra

/// What the walker is allowed to hold us responsible for.
///
/// The walk enumerates the filesystem, so it has always audited whatever happened to be on disk.
/// That is how a deadlock in a vendored `development-guidelines/setup.swift` was found — a real
/// bug, fixed at its source. It is also how a vendored tree gets held to house rules it never
/// agreed to, which is incoherent for a `convention`-kind checker and gets worse as `bounded-io`
/// lands: a dependency full of raw `Process()` would go red on a rule that is ours, not theirs.
///
/// The line drawn here is **git-ignored**, because that is someone deliberately declaring a path
/// outside the repository. It generalises: the next vendored tree lands in `.gitignore` as a
/// matter of course, with no list for anyone to remember to update.
@Suite("SourceWalker — what counts as ours")
struct SourceWalkerIgnoreTests {

    private func makeRepo() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qg-walker-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func git(_ args: [String], in root: URL) throws {
        _ = try ProcessRunner.run("/usr/bin/git", arguments: args, currentDirectory: root.path, timeout: 30)
    }

    /// The case that motivated the change.
    @Test("a git-ignored vendored tree is not walked")
    func ignoredTreeIsSkipped() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)
        try "/vendored/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let vendored = root.appendingPathComponent("vendored")
        try FileManager.default.createDirectory(at: vendored, withIntermediateDirectories: true)
        try "func theirs() {}".write(to: vendored.appendingPathComponent("Theirs.swift"), atomically: true, encoding: .utf8)

        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "func ours() {}".write(to: sources.appendingPathComponent("Ours.swift"), atomically: true, encoding: .utf8)

        let found = SourceWalker.swiftFiles(under: root)
        #expect(found.contains { $0.hasSuffix("Ours.swift") })
        #expect(!found.contains { $0.hasSuffix("Theirs.swift") }, "a git-ignored tree must be out of scope")
    }

    /// **The distinction the whole change turns on.**
    ///
    /// Ignored and untracked are easy to conflate, and conflating them would be worse than the
    /// bug being fixed. A `.swift` file written a minute ago and not yet `git add`ed is untracked
    /// and entirely ours. If the walker skipped untracked files you could add a checker, watch
    /// the gate pass, and then turn it red purely by staging the file — the gate's verdict would
    /// depend on the index rather than on the code.
    @Test("a brand-new unstaged file is still ours")
    func untrackedButNotIgnoredIsStillWalked() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)

        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        // Never added to the index — untracked, but nobody declared it outside the repository.
        try "func brandNew() {}".write(to: sources.appendingPathComponent("BrandNew.swift"), atomically: true, encoding: .utf8)

        let found = SourceWalker.swiftFiles(under: root)
        #expect(found.contains { $0.hasSuffix("BrandNew.swift") },
                "untracked is not ignored — the gate must not depend on what has been staged")
    }

    /// Foreign mode points the gate at packages that may not be git repositories at all. Losing
    /// the walk there would silently reduce a survey to nothing, which is the failure mode this
    /// whole session has been about.
    @Test("a directory that is not a git repository is walked in full")
    func nonGitDirectoryIsUnaffected() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "func stranger() {}".write(to: sources.appendingPathComponent("Stranger.swift"), atomically: true, encoding: .utf8)

        let found = SourceWalker.swiftFiles(under: root)
        #expect(found.contains { $0.hasSuffix("Stranger.swift") },
                "no git, no exclusion — a survey of a stranger's package must still see everything")
    }

    /// A single ignored file, not a whole tree — the same rule at finer grain.
    @Test("an individually ignored file is skipped")
    func individuallyIgnoredFileIsSkipped() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(["init", "-q"], in: root)
        try "Generated.swift\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "func generated() {}".write(to: sources.appendingPathComponent("Generated.swift"), atomically: true, encoding: .utf8)
        try "func kept() {}".write(to: sources.appendingPathComponent("Kept.swift"), atomically: true, encoding: .utf8)

        let found = SourceWalker.swiftFiles(under: root)
        #expect(found.contains { $0.hasSuffix("Kept.swift") })
        #expect(!found.contains { $0.hasSuffix("Generated.swift") })
    }
}
