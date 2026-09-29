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
