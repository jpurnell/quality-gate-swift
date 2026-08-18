import Foundation
import Testing
import QualityGateCore
@testable import IndexStoreInfra

@Suite("SourceCacheInputs")
struct SourceCacheInputsTests {

    @Test("Scopes to Sources/Tests + manifests, and does NOT descend into .build")
    func scopedToSourcesNotBuild() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qg-sci-\(UUID().uuidString)")
        // A miniature project layout, including a .build/checkouts dependency source.
        let layout = [
            "Sources/App/a.swift",
            "Tests/AppTests/b.swift",
            ".build/checkouts/Dep/c.swift",   // must be excluded — this was the perf bug
            "Package.swift",
        ]
        for rel in layout {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// x".write(to: url, atomically: true, encoding: .utf8)
        }

        let inputs = SourceCacheInputs.wholeSource(projectRoot: root, configuration: Configuration())

        #expect(inputs.files.contains { $0.hasSuffix("Sources/App/a.swift") })
        #expect(inputs.files.contains { $0.hasSuffix("Tests/AppTests/b.swift") })
        #expect(inputs.files.contains { $0.hasSuffix("Package.swift") })
        #expect(inputs.files.contains { $0.hasSuffix("Package.resolved") })  // included even if absent
        // The regression guard: never hash the dependency tree under .build.
        #expect(!inputs.files.contains { $0.contains("/.build/") })
    }

    @Test("Snapshot semantics: the source walk is memoized for the process")
    func walkMemoizedPerProcess() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qg-sci-memo-\(UUID().uuidString)")
        let first = root.appendingPathComponent("Sources/App/a.swift")
        try fm.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// x".write(to: first, atomically: true, encoding: .utf8)

        let before = SourceCacheInputs.wholeSource(projectRoot: root, configuration: Configuration())

        // A file created mid-process must not appear: every checker in a run fingerprints
        // the same tree snapshot, which is what makes one walk shareable across ~41 checkers.
        let late = root.appendingPathComponent("Sources/App/late.swift")
        try "// late".write(to: late, atomically: true, encoding: .utf8)
        let after = SourceCacheInputs.wholeSource(projectRoot: root, configuration: Configuration())

        #expect(after.files == before.files)
        #expect(!after.files.contains { $0.hasSuffix("late.swift") })
    }

    @Test("Distinct roots are distinct memo entries")
    func distinctRootsDistinctWalks() throws {
        let fm = FileManager.default
        var paths: [[String]] = []
        for marker in ["one", "two"] {
            let root = fm.temporaryDirectory.appendingPathComponent("qg-sci-root-\(marker)-\(UUID().uuidString)")
            let file = root.appendingPathComponent("Sources/App/\(marker).swift")
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// \(marker)".write(to: file, atomically: true, encoding: .utf8)
            paths.append(SourceCacheInputs.wholeSource(projectRoot: root, configuration: Configuration()).files)
        }
        #expect(paths[0].contains { $0.hasSuffix("one.swift") })
        #expect(paths[1].contains { $0.hasSuffix("two.swift") })
        #expect(!paths[1].contains { $0.hasSuffix("one.swift") })
    }

    @Test("Exclude patterns are part of the memo key")
    func excludePatternsKeyTheWalk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qg-sci-excl-\(UUID().uuidString)")
        for rel in ["Sources/App/keep.swift", "Sources/Generated/skip.swift"] {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// x".write(to: url, atomically: true, encoding: .utf8)
        }
        var excluding = Configuration()
        excluding.excludePatterns = ["Generated"]

        let unfiltered = SourceCacheInputs.wholeSource(projectRoot: root, configuration: Configuration())
        let filtered = SourceCacheInputs.wholeSource(projectRoot: root, configuration: excluding)

        #expect(unfiltered.files.contains { $0.hasSuffix("skip.swift") })
        #expect(!filtered.files.contains { $0.hasSuffix("skip.swift") })
        #expect(filtered.files.contains { $0.hasSuffix("keep.swift") })
    }
}
