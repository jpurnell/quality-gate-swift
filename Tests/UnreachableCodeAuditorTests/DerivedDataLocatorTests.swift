import Foundation
import Testing
@testable import UnreachableCodeAuditor

@Suite("DerivedData locator")
struct DerivedDataLocatorTests {

    private func makeFakeDerivedDataRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Plant a fake DerivedData entry. Returns the resulting DataStore URL.
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

        let found = IndexStoreManager.locateInDerivedData(
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

        let found = IndexStoreManager.locateInDerivedData(
            projectName: "MyApp",
            projectPath: proj,
            derivedDataRoot: dd)
        #expect(found?.standardizedFileURL == newer.standardizedFileURL)
    }

    @Test("Returns nil when no entry matches")
    func returnsNilWhenNoMatch() throws {
        let dd = try makeFakeDerivedDataRoot()
        defer { try? FileManager.default.removeItem(at: dd) }
        let found = IndexStoreManager.locateInDerivedData(
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
        let found = IndexStoreManager.locateInDerivedData(
            projectName: "App",
            projectPath: URL(fileURLWithPath: "/expected/App.xcodeproj"),
            derivedDataRoot: dd)
        #expect(found == nil)
    }
}
