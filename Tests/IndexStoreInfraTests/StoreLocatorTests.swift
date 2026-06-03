import Foundation
import Testing
@testable import IndexStoreInfra

@Suite("StoreLocator — DerivedData location")
struct DerivedDataLocationTests {

    private func makeFakeDerivedDataRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func plantEntry(
        in derivedDataRoot: URL,
        name: String,
        hash: String,
        workspacePath: String?
    ) throws -> URL {
        let entry = derivedDataRoot.appendingPathComponent("\(name)-\(hash)")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let store = entry.appendingPathComponent("Index.noindex/DataStore")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        if let workspacePath {
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: ["WorkspacePath": workspacePath] as [String: Any],
                format: .xml,
                options: 0)
            try plistData.write(to: entry.appendingPathComponent("info.plist"))
        }
        return store
    }

    @Test("Finds entry by sanitized project name")
    func findsEntry() throws {
        let dd = try makeFakeDerivedDataRoot()
        defer { try? FileManager.default.removeItem(at: dd) }
        let proj = URL(fileURLWithPath: "/some/path/WineTaster 4.xcodeproj")
        let store = try plantEntry(in: dd, name: "WineTaster_4", hash: "abc123", workspacePath: proj.path)

        let found = StoreLocator.locateInDerivedData(
            projectName: "WineTaster 4",
            projectPath: proj,
            derivedDataRoot: dd)
        #expect(found?.standardizedFileURL == store.standardizedFileURL)
    }

    @Test("Picks newest of multiple matches")
    func picksNewest() throws {
        let dd = try makeFakeDerivedDataRoot()
        defer { try? FileManager.default.removeItem(at: dd) }
        let proj = URL(fileURLWithPath: "/some/MyApp.xcodeproj")
        _ = try plantEntry(in: dd, name: "MyApp", hash: "old", workspacePath: proj.path)
        Thread.sleep(forTimeInterval: 0.05)
        let newer = try plantEntry(in: dd, name: "MyApp", hash: "new", workspacePath: proj.path)

        let found = StoreLocator.locateInDerivedData(
            projectName: "MyApp",
            projectPath: proj,
            derivedDataRoot: dd)
        #expect(found?.standardizedFileURL == newer.standardizedFileURL)
    }

    @Test("Returns nil when no entry matches")
    func returnsNilWhenNoMatch() throws {
        let dd = try makeFakeDerivedDataRoot()
        defer { try? FileManager.default.removeItem(at: dd) }
        let found = StoreLocator.locateInDerivedData(
            projectName: "Nope",
            projectPath: URL(fileURLWithPath: "/x.xcodeproj"),
            derivedDataRoot: dd)
        #expect(found == nil)
    }

    @Test("Skips entries whose info.plist references a different workspace")
    func skipsMismatchedWorkspace() throws {
        let dd = try makeFakeDerivedDataRoot()
        defer { try? FileManager.default.removeItem(at: dd) }
        _ = try plantEntry(in: dd, name: "App", hash: "abc", workspacePath: "/different/App.xcodeproj")
        let found = StoreLocator.locateInDerivedData(
            projectName: "App",
            projectPath: URL(fileURLWithPath: "/expected/App.xcodeproj"),
            derivedDataRoot: dd)
        #expect(found == nil)
    }
}

@Suite("StoreLocator — staleness checking")
struct StalenessTests {

    @Test("Store is stale when swift files are newer")
    func staleWhenSourceNewer() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-\(UUID().uuidString)")
        let store = tmp.appendingPathComponent("store")
        let sources = tmp.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pastDate = Date().addingTimeInterval(-100)
        try FileManager.default.setAttributes(
            [.modificationDate: pastDate],
            ofItemAtPath: store.path)

        try "let x = 1".write(
            to: sources.appendingPathComponent("test.swift"),
            atomically: true,
            encoding: .utf8)

        #expect(StoreLocator.isIndexStoreStale(store: store, sourcesRoot: sources))
    }

    @Test("Store is fresh when no swift files are newer")
    func freshWhenStoreNewer() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-\(UUID().uuidString)")
        let store = tmp.appendingPathComponent("store")
        let sources = tmp.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pastDate = Date().addingTimeInterval(-100)
        let swiftFile = sources.appendingPathComponent("old.swift")
        try "let x = 1".write(to: swiftFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: pastDate],
            ofItemAtPath: swiftFile.path)

        #expect(!StoreLocator.isIndexStoreStale(store: store, sourcesRoot: sources))
    }
}

@Suite("StoreLocator — xcodebuild scheme picker")
struct SchemePickerTests {

    @Test("Picks first scheme from project listing")
    func projectListing() throws {
        let json = #"""
        {
          "project": {
            "name": "MyApp",
            "schemes": ["MyApp", "MyApp Tests", "Helper"]
          }
        }
        """#.data(using: .utf8)!
        let scheme = try StoreLocator.firstScheme(fromXcodebuildListJSON: json)
        #expect(scheme == "MyApp")
    }

    @Test("Picks first scheme from workspace listing")
    func workspaceListing() throws {
        let json = #"""
        {
          "workspace": {
            "name": "MyWorkspace",
            "schemes": ["AppA", "AppB"]
          }
        }
        """#.data(using: .utf8)!
        let scheme = try StoreLocator.firstScheme(fromXcodebuildListJSON: json)
        #expect(scheme == "AppA")
    }

    @Test("Throws when no schemes")
    func noSchemes() {
        let json = #"{"project": {"name": "X", "schemes": []}}"#.data(using: .utf8)!
        #expect(throws: Swift.Error.self) {
            _ = try StoreLocator.firstScheme(fromXcodebuildListJSON: json)
        }
    }

    @Test("Throws on malformed JSON")
    func malformed() {
        let json = "garbage".data(using: .utf8)!
        #expect(throws: Swift.Error.self) {
            _ = try StoreLocator.firstScheme(fromXcodebuildListJSON: json)
        }
    }
}

@Suite("ProjectKind detection")
struct ProjectKindDetectionTests {

    @Test("Detects SwiftPM package")
    func detectsSwiftPM() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "// swift-tools-version: 6.2".write(
            to: tmp.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8)

        let kind = ProjectKind.detect(at: tmp)
        guard case .swiftPM(let packageRoot) = kind else {
            Issue.record("Expected .swiftPM, got \(kind)")
            return
        }
        #expect(packageRoot.standardizedFileURL == tmp.standardizedFileURL)
    }

    @Test("Detects plain directory")
    func detectsPlain() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let kind = ProjectKind.detect(at: tmp)
        guard case .plain(let root) = kind else {
            Issue.record("Expected .plain, got \(kind)")
            return
        }
        #expect(root.standardizedFileURL == tmp.standardizedFileURL)
    }
}

@Suite("SourceWalker")
struct SourceWalkerTests {

    @Test("Finds swift files recursively")
    func findsSwiftFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("Sources/MyLib")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "let x = 1".write(to: src.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "let y = 2".write(to: src.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        try "not swift".write(to: src.appendingPathComponent("C.txt"), atomically: true, encoding: .utf8)

        let files = SourceWalker.swiftFiles(under: tmp)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.hasSuffix(".swift") })
    }

    @Test("Skips build directories")
    func skipsBuildDirs() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-skip-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("Sources")
        let build = tmp.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "let x = 1".write(to: src.appendingPathComponent("Good.swift"), atomically: true, encoding: .utf8)
        try "let y = 2".write(to: build.appendingPathComponent("Bad.swift"), atomically: true, encoding: .utf8)

        let files = SourceWalker.swiftFiles(under: tmp)
        #expect(files.count == 1)
        #expect(files[0].contains("Good.swift"))
    }

    @Test("Respects exclude patterns")
    func respectsExcludePatterns() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-excl-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("Sources")
        let gen = tmp.appendingPathComponent("Sources/Generated")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "let x = 1".write(to: src.appendingPathComponent("Keep.swift"), atomically: true, encoding: .utf8)
        try "let y = 2".write(to: gen.appendingPathComponent("Skip.swift"), atomically: true, encoding: .utf8)

        let files = SourceWalker.swiftFiles(under: tmp, excludePatterns: ["**/Generated/**"])
        #expect(files.count == 1)
        #expect(files[0].contains("Keep.swift"))
    }
}
