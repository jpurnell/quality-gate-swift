import Foundation
import Testing
@testable import DocCodeAuditor
@testable import QualityGateCore

/// The search path handed to `swiftc -I` must be the directory the module was actually found
/// in, not the directory the search started from.
///
/// SwiftPM writes either `.build/debug/<Module>.swiftmodule` or
/// `.build/debug/Modules/<Module>.swiftmodule`, and which one depends on the build system in
/// use rather than on anything the project chose. Detecting the second layout but answering
/// with the first sends `-I .build/debug` for a module one level below it, and the compiler
/// then reports `no such module '<Module>'` — a finding about this checker's own search,
/// reported against the documentation, and invisible on any machine whose layout happens to
/// be the flat one.
@Suite("Module search path")
struct ModuleSearchPathTests {

    private static func project(moduleName: String, inModulesSubdirectory: Bool) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msp-\(UUID().uuidString)")
        var directory = root.appendingPathComponent(".build/debug", isDirectory: true)
        if inModulesSubdirectory {
            directory = directory.appendingPathComponent("Modules", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("\(moduleName).swiftmodule"),
            withIntermediateDirectories: true)
        return root
    }

    @Test("A module directly under .build/debug resolves to .build/debug")
    func flatLayoutResolvesToBase() throws {
        let root = try Self.project(moduleName: "Alpha", inModulesSubdirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = ArticleDiscovery.moduleSearchPath(
            projectRoot: root, moduleName: "Alpha", configuration: Configuration())

        #expect(path == root.appendingPathComponent(".build/debug").path)
    }

    @Test("A module under .build/debug/Modules resolves to that Modules directory")
    func modulesLayoutResolvesToModules() throws {
        let root = try Self.project(moduleName: "Alpha", inModulesSubdirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = ArticleDiscovery.moduleSearchPath(
            projectRoot: root, moduleName: "Alpha", configuration: Configuration())

        #expect(path == root.appendingPathComponent(".build/debug/Modules").path)
    }

    @Test("A project with nothing built resolves to nil, so the checker can skip")
    func nothingBuiltIsNil() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = ArticleDiscovery.moduleSearchPath(
            projectRoot: root, moduleName: "Alpha", configuration: Configuration())

        #expect(path == nil)
    }
}
