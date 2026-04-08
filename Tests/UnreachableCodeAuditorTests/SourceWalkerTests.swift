import Foundation
import Testing
@testable import UnreachableCodeAuditor

@Suite("SourceWalker")
struct SourceWalkerTests {

    private func makeTree(_ files: [String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swtest-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for relPath in files {
            let url = root.appendingPathComponent(relPath)
            try! FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try! "".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func names(_ paths: [String]) -> Set<String> {
        Set(paths.map { ($0 as NSString).lastPathComponent })
    }

    @Test("Walks .swift files recursively")
    func walksRecursively() {
        let root = makeTree(["a.swift", "Sub/b.swift", "Deep/Nested/c.swift", "ignore.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SourceWalker.swiftFiles(under: root)
        #expect(names(files) == ["a.swift", "b.swift", "c.swift"])
    }

    @Test("Skips build / dependency directories")
    func skipsBuildDirs() {
        let root = makeTree([
            "Sources/keep.swift",
            ".build/skip.swift",
            ".swiftpm/skip.swift",
            "DerivedData/skip.swift",
            "build/skip.swift",
            "Pods/skip.swift",
            "Carthage/skip.swift",
            "node_modules/skip.swift",
            ".git/skip.swift",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SourceWalker.swiftFiles(under: root)
        #expect(names(files) == ["keep.swift"])
    }

    @Test("Skips inside .xcodeproj and .xcworkspace")
    func skipsXcodeContainers() {
        let root = makeTree([
            "App.swift",
            "Project.xcodeproj/internal.swift",
            "Workspace.xcworkspace/internal.swift",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SourceWalker.swiftFiles(under: root)
        #expect(names(files) == ["App.swift"])
    }

    @Test("Honors excludePatterns")
    func honorsExcludes() {
        let root = makeTree(["a.swift", "Generated/b.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = SourceWalker.swiftFiles(under: root, excludePatterns: ["**/Generated/**"])
        #expect(names(files) == ["a.swift"])
    }
}
