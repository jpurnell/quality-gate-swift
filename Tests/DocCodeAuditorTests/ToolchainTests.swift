import Foundation
import Testing
@testable import DocCodeAuditor
@testable import QualityGateCore

/// The compiler that typechecks a documentation block must be the one that built the module
/// the block imports.
///
/// `xcrun -f swiftc` answers with Xcode's compiler, which is not necessarily the one
/// `swift build` ran. On a CI job that installs a toolchain, the installed compiler is on
/// `PATH` and Xcode's is what `xcrun` returns — two different compilers in one job. The
/// module written by the first cannot be read by the second, and the diagnostic for that is
/// `no such module`, which reads exactly like a missing dependency in the documentation.
@Suite("Toolchain resolution")
struct ToolchainTests {

    /// A toolchain-shaped directory, returning the `usr/bin` a `PATH` would name.
    ///
    /// Shaped as `<root>/usr/bin/swiftc` rather than `<dir>/swiftc` because the code under test
    /// derives a toolchain root by walking *two* levels up from the compiler. A flat fixture
    /// derives `/tmp` and would pass or fail for reasons the real layout never has.
    private static func binDirectory(containingSwiftc: Bool) throws -> URL {
        let bin = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tc-\(UUID().uuidString)")
            .appendingPathComponent("usr")
            .appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if containingSwiftc {
            let swiftc = bin.appendingPathComponent("swiftc")
            try "#!/bin/sh\n".write(to: swiftc, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: swiftc.path)
        }
        return bin
    }

    /// The `usr` a candidate in `bin` derives to, which is what the predicate is handed.
    private static func usr(of bin: URL) -> String {
        bin.deletingLastPathComponent().path
    }

    @Test("`swiftc` on PATH is preferred over the one xcrun would answer with")
    func pathEntryIsFound() throws {
        let dir = try Self.binDirectory(containingSwiftc: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = Toolchain.swiftcOnPath(
            path: dir.path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            isToolchainRoot: { _ in true })

        #expect(found == dir.appendingPathComponent("swiftc").path)
    }

    @Test("The first PATH entry holding `swiftc` wins, as the shell would resolve it")
    func earlierPathEntryWins() throws {
        let first = try Self.binDirectory(containingSwiftc: true)
        let second = try Self.binDirectory(containingSwiftc: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let found = Toolchain.swiftcOnPath(
            path: "\(first.path):\(second.path)",
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            isToolchainRoot: { _ in true })

        #expect(found == first.appendingPathComponent("swiftc").path)
    }

    @Test("A PATH with no `swiftc` resolves to nil, so the caller can fall back to xcrun")
    func absentSwiftcIsNil() throws {
        let dir = try Self.binDirectory(containingSwiftc: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let found = Toolchain.swiftcOnPath(
            path: dir.path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            isToolchainRoot: { _ in true })

        #expect(found == nil)
    }

    @Test("An unset PATH resolves to nil rather than trapping")
    func unsetPathIsNil() {
        let found = Toolchain.swiftcOnPath(
            path: nil,
            isExecutable: { _ in true },
            isToolchainRoot: { _ in true })

        #expect(found == nil)
    }

    @Test("An empty PATH entry is skipped rather than resolving to a bare `/swiftc`")
    func emptyEntriesAreSkipped() {
        var probed: [String] = []
        let found = Toolchain.swiftcOnPath(
            path: "::",
            isExecutable: { probed.append($0); return true },
            isToolchainRoot: { _ in true })

        #expect(found == nil)
        #expect(probed.isEmpty)
    }

    /// `/usr/bin/swiftc` is a shim, not a toolchain.
    ///
    /// It is executable and it is first on `PATH` on every Mac, but the directory two levels
    /// above it is `/usr`, which holds neither the testing plugins nor `ManifestAPI`. Accepting
    /// it would drop `-plugin-path` and `-I <ManifestAPI>` from every compile — so a documented
    /// `@Test` block fails on `no such module 'Testing'` and a documented `Package.swift`
    /// excerpt on `no such module 'PackageDescription'`. Both read as documentation defects.
    @Test("A shim on PATH is skipped in favour of a real toolchain further along it")
    func shimIsSkippedForRealToolchain() throws {
        let shim = try Self.binDirectory(containingSwiftc: true)
        let real = try Self.binDirectory(containingSwiftc: true)
        defer {
            try? FileManager.default.removeItem(at: shim)
            try? FileManager.default.removeItem(at: real)
        }

        let found = Toolchain.swiftcOnPath(
            path: "\(shim.path):\(real.path)",
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            isToolchainRoot: { $0 == Self.usr(of: real) })

        #expect(found == real.appendingPathComponent("swiftc").path)
    }

    @Test("A PATH holding only a shim resolves to nil, so xcrun still answers")
    func shimOnlyPathIsNil() throws {
        let shim = try Self.binDirectory(containingSwiftc: true)
        defer { try? FileManager.default.removeItem(at: shim) }

        let found = Toolchain.swiftcOnPath(
            path: shim.path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            isToolchainRoot: { _ in false })

        #expect(found == nil)
    }
}

/// Which executable the checker actually invokes to compile a block.
///
/// Distinct from ``ToolchainTests``, which covers how the *flags* are probed. The flags were
/// resolved from `PATH` and the invocation was not: it ran a hardcoded `/usr/bin/xcrun`, a
/// file that does not exist off Darwin. Every documentation checker therefore failed on Linux
/// with `could not run swiftc: The file doesn’t exist` — reported against the article, at
/// line 1, as though the documentation were at fault.
@Suite("Compiler invocation")
struct CompilerInvocationTests {

    @Test("A toolchain on PATH is invoked directly, with no xcrun in front of it")
    func pathToolchainIsInvokedDirectly() {
        let resolved = Toolchain.resolveCompiler(
            onPath: { "/opt/swift/usr/bin/swiftc" },
            xcrunFindsSwiftc: { "/Applications/Xcode.app/…/usr/bin/swiftc" },
            xcrunExists: { true })

        #expect(resolved?.executable == "/opt/swift/usr/bin/swiftc")
        #expect(resolved?.prefixArguments == [])
    }

    /// The normal Mac shape: `PATH` offers only the `/usr/bin/swiftc` shim, which
    /// ``Toolchain/swiftcOnPath(path:isExecutable:isToolchainRoot:)`` rejects, so `xcrun`
    /// answers — and its answer is an absolute compiler path, invocable on its own.
    @Test("With no toolchain on PATH, xcrun's answer is invoked directly")
    func xcrunAnswerIsInvokedDirectly() {
        let resolved = Toolchain.resolveCompiler(
            onPath: { nil },
            xcrunFindsSwiftc: { "/Applications/Xcode.app/usr/bin/swiftc" },
            xcrunExists: { true })

        #expect(resolved?.executable == "/Applications/Xcode.app/usr/bin/swiftc")
        #expect(resolved?.prefixArguments == [])
    }

    /// Kept so macOS behaviour is a superset of what it was: if `xcrun -f swiftc` fails for a
    /// transient reason, the previous code would still have compiled, and so does this.
    @Test("With no answer from either probe, xcrun itself is the last resort")
    func xcrunIsTheLastResort() {
        let resolved = Toolchain.resolveCompiler(
            onPath: { nil },
            xcrunFindsSwiftc: { nil },
            xcrunExists: { true })

        #expect(resolved?.executable == "/usr/bin/xcrun")
        #expect(resolved?.prefixArguments == ["swiftc"])
    }

    /// The Linux case. Resolving to `nil` is what lets the caller say *the toolchain could not
    /// be found* instead of blaming the article it was about to typecheck.
    @Test("With no compiler and no xcrun, resolution fails rather than naming a missing file")
    func noCompilerResolvesToNil() {
        let resolved = Toolchain.resolveCompiler(
            onPath: { nil },
            xcrunFindsSwiftc: { nil },
            xcrunExists: { false })

        #expect(resolved == nil)
    }

    @Test("Arguments are composed after the prefix the executable needs")
    func argumentsComposeAfterPrefix() {
        let direct = Toolchain.Compiler(executable: "/opt/swift/usr/bin/swiftc", prefixArguments: [])
        #expect(direct.arguments(["-typecheck", "a.swift"]) == ["-typecheck", "a.swift"])

        let viaXcrun = Toolchain.Compiler(executable: "/usr/bin/xcrun", prefixArguments: ["swiftc"])
        #expect(viaXcrun.arguments(["-typecheck", "a.swift"]) == ["swiftc", "-typecheck", "a.swift"])
    }
}

/// Which built libraries an article's imports resolve to.
///
/// The suffix list is how `linkArguments` decides a module has something to link against.
/// It named `a`, `dylib` and `tbd` — the first is shared with Linux, the other two are
/// Darwin's. A SwiftPM package whose product is dynamic builds `lib<Module>.so` there, and a
/// list without `so` silently contributes no `-l`: the article then fails to link, and
/// `undefined symbol` is indistinguishable from an article importing a module it should not.
@Suite("Link arguments")
struct LinkArgumentsTests {

    /// Creates a directory holding `lib<module>.<suffix>`, returning the directory.
    private static func searchPath(library module: String, suffix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("lib\(module).\(suffix)"))
        return dir
    }

    @Test("Every platform's library suffix resolves to a -l flag",
          arguments: ["a", "dylib", "tbd", "so"])
    func suffixResolvesToLinkFlag(suffix: String) throws {
        let dir = try Self.searchPath(library: "Demo", suffix: suffix)
        defer { try? FileManager.default.removeItem(at: dir) }

        let arguments = ArticleRunner.linkArguments(
            imports: ["Demo"], searchPaths: [dir.path], source: "import Demo\n")

        #expect(arguments.contains("-lDemo"), "lib Demo.\(suffix) should have been linked")
    }

    /// The documented behaviour, and the reason the suffix list cannot simply match anything:
    /// a module with nothing built beside it contributes no `-l` rather than a link error.
    @Test("A module with no built library contributes no -l flag")
    func absentLibraryContributesNothing() throws {
        let dir = try Self.searchPath(library: "Demo", suffix: "so")
        defer { try? FileManager.default.removeItem(at: dir) }

        let arguments = ArticleRunner.linkArguments(
            imports: ["Absent"], searchPaths: [dir.path], source: "import Absent\n")

        #expect(!arguments.contains("-lAbsent"))
        #expect(arguments == ["-L", dir.path])
    }
}
