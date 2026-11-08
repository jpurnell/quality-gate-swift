import Foundation
import IndexStoreInfra
import QualityGateCore
import Testing
@testable import UnreachableCodeAuditor

/// One source file compiled into more than one module.
///
/// An Xcode project with a target per platform compiles its shared files once per target, and
/// each target is its own module. The index then holds every declaration of a shared file under
/// one USR per module — `s:7TargetA6SharedV…` and `s:7TargetB6SharedV…` — and each module's
/// references point at its own copy. A call that only one target compiles (a file the other
/// target leaves out, or a branch of `#if os(…)`) reaches one copy and not the other.
///
/// Found in KEXPPower, whose `Spinner TV` target compiles the iOS app's sources: the archive
/// player's `scrub(toFraction:)` is called only from the `Slider` branch tvOS does not have,
/// and was reported unreachable — from the tvOS copy — though iOS calls it.
///
/// The store is built with `swiftc` rather than a package, because SwiftPM does not let two
/// targets share a source file, and the property under test is what IndexStoreDB returns for
/// a real store.
@Suite("Unreachable: a source compiled into several modules", .serialized)
struct SharedSourceTests {

    private static let ruleId = "unreachable.cross_module.unreachable_from_entry"

    /// The shared files. Several rather than one, because which compilation of a file the
    /// index's file queries answer from is decided by the hash of the unit's name, not by build
    /// order: a single file reproduces the defect only when the hash happens to favour the
    /// module that does not call it.
    private static let sharedNames = (1...6).map { "Shared\($0)" }

    /// A type both targets compile, with one method only target A calls and one nothing calls.
    private static func shared(_ name: String) -> String {
        """
        /// A type both targets compile.
        public struct \(name) {
            /// Creates one.
            public init() {}
            /// Called only from target A's own file.
            func usedOnlyByA\(name)() -> Int { 1 }
            /// Called by nothing, in either target.
            func neverCalled\(name)() -> Int { 2 }
        }

        """
    }

    private static var entryA: String {
        let calls = sharedNames.map { "\($0)().usedOnlyByA\($0)()" }.joined(separator: " + ")
        return """
            /// Target A's entry.
            public func entryA() -> Int { \(calls) }

            """
    }

    private static let entryB = """
        /// Target B's entry: compiles the shared types and calls none of them.
        public func entryB() -> Int { 0 }

        """

    private struct BuildFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Compiles `files` into module `module`, indexing into `store`.
    private static func compile(
        module: String, files: [URL], store: URL, outputDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let result = try ProcessRunner.run(
            "/usr/bin/env",
            arguments: ["swiftc", "-parse-as-library", "-module-name", module,
                        "-index-store-path", store.path, "-c"] + files.map(\.path),
            currentDirectory: outputDirectory.path,
            mergeStderr: true,
            timeout: 300)
        guard result.exitCode == 0 else {
            throw BuildFailure(description: "swiftc for \(module) failed: \(result.stdout)")
        }
    }

    private func flagged(_ diagnostics: [Diagnostic]) -> [String] {
        diagnostics.filter { $0.ruleId == Self.ruleId }.map(\.message).sorted()
    }

    @Test("a symbol one module calls is live; one no module calls is reported once")
    func reachableFromAnyModule() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-shared-source-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer {
            // silent: best-effort cleanup of a test-private fixture directory
            try? FileManager.default.removeItem(at: root)
        }
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var shared: [URL] = []
        for name in Self.sharedNames {
            let file = sources.appendingPathComponent("\(name).swift")
            try Self.shared(name).write(to: file, atomically: true, encoding: .utf8)
            shared.append(file)
        }
        let entryA = sources.appendingPathComponent("EntryA.swift")
        let entryB = sources.appendingPathComponent("EntryB.swift")
        try Self.entryA.write(to: entryA, atomically: true, encoding: .utf8)
        try Self.entryB.write(to: entryB, atomically: true, encoding: .utf8)

        let store = root.appendingPathComponent("build/index-store", isDirectory: true)
        try Self.compile(module: "TargetA", files: shared + [entryA], store: store,
                         outputDirectory: root.appendingPathComponent("build/TargetA"))
        try Self.compile(module: "TargetB", files: shared + [entryB], store: store,
                         outputDirectory: root.appendingPathComponent("build/TargetB"))

        let library = try #require(IndexStoreSession.findLibIndexStore())
        let pass = try await IndexStorePass.runRecordingMarkers(inputs: IndexStorePass.Inputs(
            rootURL: sources, excludePatterns: [], indexStorePath: store,
            libIndexStoreDylib: library, targetTypeByModule: [:]))
        await SharedIndexStore.drain()
        let found = flagged(pass.diagnostics)

        let wronglyFlagged = found.filter { $0.contains("usedOnlyByA") }
        #expect(wronglyFlagged.isEmpty,
                "declarations one module reaches were reported from another module's copy: \(wronglyFlagged)")
        for name in Self.sharedNames {
            #expect(found.filter { $0.contains("neverCalled\(name)()") }.count == 1,
                    "a declaration no module reaches must be reported, once: \(found)")
        }
        #expect(found.count == Self.sharedNames.count,
                "expected only the neverCalled methods; got \(found)")
    }
}
