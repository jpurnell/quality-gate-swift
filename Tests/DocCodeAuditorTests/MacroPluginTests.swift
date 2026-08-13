import Foundation
import Testing
@testable import DocCodeAuditor
@testable import QualityGateCore

/// A package's own macros must be loadable, or every fence that uses one fails for a reason the
/// author did not cause.
///
/// The toolchain's swift-testing plugin was already handled, and `PackageDescription` already had
/// its include path added, both for the same reason recorded there: a gate that cannot compile a
/// legitimate construct gets an exemption written for it, and the exemption looks exactly like
/// compliance. A package's own macro plugin is the third instance — 25 errors from one root
/// cause on a 100k-line package, every one of them reading as a documentation defect.
@Suite("Macro plugins")
struct MacroPluginTests {

    @Test("Macro targets are read from the manifest")
    func macroTargetsAreFound() {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        import CompilerPluginSupport

        let package = Package(
            name: "example",
            targets: [
                .target(name: "Example", dependencies: ["ExampleMacros"]),
                .macro(name: "ExampleMacros", dependencies: []),
                .macro(name: "OtherMacrosImpl"),
                .testTarget(name: "ExampleTests"),
            ]
        )
        """

        #expect(MacroPlugins.macroTargets(in: manifest) == ["ExampleMacros", "OtherMacrosImpl"])
    }

    @Test("A manifest declaring no macros yields none")
    func noMacros() {
        #expect(MacroPlugins.macroTargets(in: """
        let package = Package(name: "x", targets: [.target(name: "X")])
        """).isEmpty)
    }

    @Test("A built plugin becomes a -load-plugin-executable flag naming its module")
    func builtPluginBecomesAFlag() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macro-\(UUID().uuidString)")
        let build = root.appendingPathComponent(".build/debug")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        let package = Package(name: "x", targets: [.macro(name: "ExampleMacros")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(
            to: build.appendingPathComponent("ExampleMacros"), atomically: true, encoding: .utf8)

        let flags = MacroPlugins.flags(projectRoot: root, buildDirectory: build.path)

        #expect(flags.count == 2)
        #expect(flags[0] == "-load-plugin-executable")
        #expect(flags[1].hasSuffix("ExampleMacros#ExampleMacros"))
    }

    @Test("A declared but unbuilt macro yields no flag rather than a broken one")
    func unbuiltMacroYieldsNothing() throws {
        // The compiler's own "external macro implementation not found" is a true statement about
        // the tree and points somewhere useful. A flag naming a file that does not exist would
        // fail the whole compilation with something about the gate's environment instead.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macro-\(UUID().uuidString)")
        let build = root.appendingPathComponent(".build/debug")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        let package = Package(name: "x", targets: [.macro(name: "NeverBuilt")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        #expect(MacroPlugins.flags(projectRoot: root, buildDirectory: build.path).isEmpty)
    }

    @Test("A directory with no manifest is not a package")
    func noManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(MacroPlugins.flags(projectRoot: root, buildDirectory: root.path).isEmpty)
    }
}
