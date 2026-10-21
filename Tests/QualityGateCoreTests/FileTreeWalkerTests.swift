import Foundation
import Testing
@testable import QualityGateCore

// MARK: - Helpers

/// A small project tree: `Package.swift`, two source files a level apart, a hidden file and a
/// hidden directory.
private func makeTree() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("qg-tree-walker-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("Sources/Quiet/Generated"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
    for (path, text) in [
        ("Package.swift", "a"),
        ("Sources/Quiet/Quiet.swift", "b"),
        ("Sources/Quiet/Generated/Gen.swift", "c"),
        (".quality-gate.yml", "d"),
        (".hidden/inside.swift", "e"),
    ] {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    return root
}

private let fullTree = [
    ".hidden", ".hidden/inside.swift", ".quality-gate.yml", "Package.swift",
    "Sources", "Sources/Quiet", "Sources/Quiet/Generated", "Sources/Quiet/Generated/Gen.swift",
    "Sources/Quiet/Quiet.swift",
]

// MARK: - FileTreeWalker

@Suite("FileTreeWalker")
struct FileTreeWalkerTests {

    @Test("Yields every entry under the root, as paths relative to it, in sorted pre-order")
    func yieldsWholeTree() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let walked = FileTreeWalker(root: root.path).map(\.relativePath)
        #expect(walked == fullTree)
    }

    /// The regression this type exists for. On Linux, Foundation's enumerator is built on glibc
    /// `fts` with `FTS_NOSTAT`, which counts a directory's subdirectories from its link count
    /// when the walk opens. A directory created afterwards uses up that count, and a real
    /// subdirectory is then yielded but never descended — with no error. The gate creates
    /// `.build/quality-gate-cache` part-way through a run, so a checker that opened its walk
    /// first lost `Sources/` entirely. CI measured it at 39 of 50 walks on Swift 6.4.
    @Test("A directory created after the walk starts does not truncate it", arguments: 0..<50)
    func directoryCreatedMidWalk(iteration: Int) throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let walker = FileTreeWalker(root: root.path)
        let first = walker.next()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".added-\(iteration)"), withIntermediateDirectories: false)
        let rest = Array(walker).map(\.relativePath)
        let walked = ([first?.relativePath].compactMap { $0 } + rest).filter { !$0.hasPrefix(".added-") }
        #expect(walked == fullTree)
    }

    @Test("skipsHiddenFiles leaves out dot-files and everything under dot-directories")
    func skipsHidden() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let walked = FileTreeWalker(root: root.path, options: [.skipsHiddenFiles]).map(\.relativePath)
        #expect(walked == fullTree.filter { !$0.hasPrefix(".") })
    }

    @Test("skipDescendants stops the walk entering the directory just yielded")
    func skipDescendants() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let walker = FileTreeWalker(root: root.path)
        var walked: [String] = []
        while let entry = walker.next() {
            walked.append(entry.relativePath)
            if entry.relativePath == "Sources/Quiet/Generated" { walker.skipDescendants() }
        }
        #expect(walked == fullTree.filter { $0 != "Sources/Quiet/Generated/Gen.swift" })
    }

    @Test("Entries carry kind, depth and absolute location")
    func entryFields() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = Dictionary(
            uniqueKeysWithValues: FileTreeWalker(root: root.path).map { ($0.relativePath, $0) })
        let gen = try #require(entries["Sources/Quiet/Generated/Gen.swift"])
        #expect(gen.isRegularFile)
        #expect(!gen.isDirectory)
        #expect(gen.level == 4)
        #expect(gen.path == root.appendingPathComponent("Sources/Quiet/Generated/Gen.swift").path)
        #expect(gen.url.lastPathComponent == "Gen.swift")
        let sources = try #require(entries["Sources"])
        #expect(sources.isDirectory)
        #expect(sources.level == 1)
    }

    @Test("A symbolic link to a directory is yielded but not followed")
    func symlinksNotFollowed() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Link").path,
            withDestinationPath: root.appendingPathComponent("Sources").path)
        let entries = FileTreeWalker(root: root.path).map { $0 }
        let link = try #require(entries.first { $0.relativePath == "Link" })
        #expect(link.isSymbolicLink)
        #expect(!link.isDirectory)
        #expect(!entries.contains { $0.relativePath.hasPrefix("Link/") })
    }

    @Test("A root that does not exist yields nothing and records it as unreadable")
    func missingRoot() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-tree-walker-absent-\(UUID().uuidString)").path
        let walker = FileTreeWalker(root: absent)
        #expect(Array(walker).isEmpty)
        #expect(walker.unreadableDirectories == [absent])
    }

    @Test("A URL root walks the same tree as its path")
    func urlRoot() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FileTreeWalker(root: root).map(\.relativePath) == fullTree)
    }
}
