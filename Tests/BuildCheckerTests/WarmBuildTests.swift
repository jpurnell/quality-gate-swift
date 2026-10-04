import Foundation
import Testing
import QualityGateCore
@testable import BuildChecker

/// End-to-end proof that `build` reports the same warnings for the same tree whether or not
/// this run's build compiled the file that carries them.
///
/// Each test writes a package under the temporary directory and runs the real checker — the
/// real `swift build`, the real output file maps, the real `.dia` files — because the defect
/// was never in the parsing. An incremental build prints a diagnostic only for the files it
/// recompiles, so a second run on an unchanged tree printed nothing and the checker passed it.
///
/// Serialized: every test spawns several builds, and a dozen concurrent `swift build`s on a
/// loaded machine is how a three-minute limit gets missed for reasons that are not the code's.
///
/// See `quality-gate-swift-project/plans/proposals/AWarmBuildForgetsItsWarnings.md` §5, 1–11.
@Suite("BuildChecker: a warm build keeps its warnings", .serialized)
struct WarmBuildTests {

    // MARK: - 1. The same tree, twice

    @Test("An unchanged tree reports its warning on the second run too", .timeLimit(.minutes(3)))
    func warmBuildKeepsItsWarning() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }

        let cold = try await fixture.check()
        let warm = try await fixture.check()

        #expect(cold.status == .warning)
        #expect(cold.warningLocations(inFileNamed: "Warns.swift") == ["6:9"])
        #expect(warm.status == .warning, "the second run compiled nothing and must still report the warning")
        #expect(warm.warningLocations(inFileNamed: "Warns.swift") == ["6:9"])
        #expect(warm.compilerWarnings.first?.message == "result of call to 'loud()' is unused [#NoUsage]")
    }

    // MARK: - 2. Editing a neighbour

    @Test("Editing a neighbouring file does not hide the warning", .timeLimit(.minutes(3)))
    func editingANeighbourKeepsTheWarning() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }
        _ = try await fixture.check()

        try fixture.write("Sources/Fixture/Clean.swift", WarmBuildFixture.cleanSource + "// edited\n")
        let result = try await fixture.check()

        #expect(result.status == .warning)
        #expect(result.warningLocations(inFileNamed: "Warns.swift") == ["6:9"])
        #expect(result.finding("build.warnings-unverified") == nil)
    }

    // MARK: - 3. A fixed warning stays fixed

    @Test("A fixed warning is gone, and stays gone on the next run", .timeLimit(.minutes(3)))
    func fixedWarningIsNotReplayed() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }
        let before = try await fixture.check()
        #expect(before.compilerWarnings.count == 1)

        try fixture.write("Sources/Fixture/Warns.swift", WarmBuildFixture.fixedWarnsSource)
        let fixed = try await fixture.check()
        let again = try await fixture.check()

        #expect(fixed.status == .passed)
        #expect(fixed.compilerWarnings.isEmpty)
        #expect(again.status == .passed)
        #expect(again.compilerWarnings.isEmpty)
    }

    // MARK: - 4. Live

    @Test("A deleted file's warnings are not replayed from the record it left behind", .timeLimit(.minutes(3)))
    func deletedFileIsNotReplayed() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }
        try fixture.write("Sources/Fixture/Second.swift", """
            public enum Second {
                public static func caller() {
                    Warns.loud()
                }
            }

            """)
        let before = try await fixture.check()
        #expect(before.warningLocations(inFileNamed: "Second.swift") == ["3:15"])

        try fixture.delete("Sources/Fixture/Second.swift")
        let after = try await fixture.check()

        // The premise: the record outlives the file. If a toolchain starts cleaning it up, this
        // test stops proving anything and should say so.
        #expect(!fixture.buildProducts(named: "Second.dia").isEmpty)
        #expect(after.warningLocations(inFileNamed: "Second.swift").isEmpty)
        #expect(after.warningLocations(inFileNamed: "Warns.swift") == ["6:9"])
        #expect(after.finding("build.warnings-unverified") == nil)
    }

    // MARK: - 5. Once

    @Test("A declaration-level warning printed by two compile jobs is reported once", .timeLimit(.minutes(3)))
    func declarationWarningIsReportedOnce() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }
        try fixture.write("Sources/Fixture/Warns.swift", WarmBuildFixture.fixedWarnsSource)
        try fixture.write("Sources/Fixture/Decl.swift", """
            @available(*, deprecated, message: "use something else")
            public struct Old {
                public init() {}
            }

            public struct Holder {
                public var first: Old
                public var second: Old
            }

            """)

        let cold = try await fixture.check()
        let warm = try await fixture.check()

        // Emit-module and the compile job both report a deprecation in a declaration: two
        // warnings were counted as four.
        #expect(cold.warningLocations(inFileNamed: "Decl.swift") == ["7:23", "8:24"])
        #expect(warm.warningLocations(inFileNamed: "Decl.swift").sorted() == ["7:23", "8:24"])
    }

    // MARK: - 6. Local path dependency

    @Test("A warning in a local path dependency is reported on every run, and gone when fixed", .timeLimit(.minutes(3)))
    func pathDependencyWarningIsConsistent() async throws {
        let dependency = try WarmBuildFixture(name: "Dep")
        defer { dependency.remove() }
        let app = try WarmBuildFixture(
            name: "App", parent: dependency.root.deletingLastPathComponent(), dependencyPath: "../Dep")
        try app.write("Sources/App/Warns.swift", WarmBuildFixture.fixedWarnsSource)

        let cold = try await app.check()
        let warm = try await app.check()

        #expect(cold.status == .warning)
        #expect(cold.warningLocations(inFileNamed: "Warns.swift") == ["6:9"])
        #expect(cold.compilerWarnings.first?.filePath?.hasSuffix("/Dep/Sources/Dep/Warns.swift") == true)
        #expect(warm.status == .warning)
        #expect(warm.warningLocations(inFileNamed: "Warns.swift") == ["6:9"])

        try dependency.write("Sources/Dep/Warns.swift", WarmBuildFixture.fixedWarnsSource)
        let fixed = try await app.check()

        #expect(fixed.status == .passed)
        #expect(fixed.compilerWarnings.isEmpty)
    }

    // MARK: - 7. Success only

    @Test("A failed build reports its error and reads no records", .timeLimit(.minutes(3)))
    func failedBuildReadsNoRecords() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }
        _ = try await fixture.check()

        try fixture.write("Sources/Fixture/Clean.swift", """
            public enum Clean {
                public static let answer: Int = "forty-two"
            }

            """)
        let result = try await fixture.check()

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains {
            $0.severity == .error && ($0.filePath ?? "").hasSuffix("/Clean.swift")
        })
        #expect(result.finding("build.warnings-unverified") == nil)
        #expect(result.finding("build.diagnostic-coverage") == nil)
    }

    // MARK: - 8. A missing record

    @Test("A unit whose record is gone is reported as unverified, never passed", .timeLimit(.minutes(3)))
    func missingRecordIsUnverified() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }
        _ = try await fixture.check()
        let records = fixture.buildProducts(named: "Warns.dia")
        #expect(records.count == 1)

        for record in records {
            try FileManager.default.removeItem(atPath: record)
        }
        let result = try await fixture.check()

        #expect(result.status == .warning)
        // Either the build rewrote the record and the warning is back, or it did not and the
        // checker says what it could not see. What it may not do is pass.
        if result.warningLocations(inFileNamed: "Warns.swift").isEmpty {
            let finding = try #require(result.finding("build.warnings-unverified"))
            #expect(finding.severity == .warning)
            #expect(finding.message.contains("Sources/Fixture/Warns.swift"))
        }
    }

    // MARK: - 9. A corrupt record

    @Test("A unit whose record is not a .dia is reported as unverified; nothing throws", .timeLimit(.minutes(3)))
    func corruptRecordIsUnverified() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }
        _ = try await fixture.check()
        let records = fixture.buildProducts(named: "Warns.dia")
        #expect(records.count == 1)

        let arbitrary = Data([0x9E, 0x37, 0x79, 0xB9, 0x7F, 0x4A, 0x7C, 0x15, 0xF3, 0x9C, 0xC0, 0x60, 0x5C, 0xED, 0xC8, 0x34])
        for record in records {
            try arbitrary.write(to: URL(fileURLWithPath: record))
        }
        let result = try await fixture.check()

        #expect(result.status == .warning)
        if result.warningLocations(inFileNamed: "Warns.swift").isEmpty {
            let finding = try #require(result.finding("build.warnings-unverified"))
            #expect(finding.message.contains("Sources/Fixture/Warns.swift"))
        }
    }

    // MARK: - 10. Release

    @Test("A release build's module-level record is read on the second run", .timeLimit(.minutes(3)))
    func releaseBuildKeepsItsWarning() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }

        let cold = try await fixture.check(buildConfiguration: "release")
        let warm = try await fixture.check(buildConfiguration: "release")

        #expect(cold.status == .warning)
        #expect(cold.warningLocations(inFileNamed: "Warns.swift") == ["6:9"])
        #expect(warm.status == .warning)
        #expect(warm.warningLocations(inFileNamed: "Warns.swift") == ["6:9"])
    }

    // MARK: - 11. Coverage

    @Test("The coverage note says what this run compiled and what it read", .timeLimit(.minutes(3)))
    func coverageNoteDistinguishesCompiledFromRead() async throws {
        let fixture = try WarmBuildFixture()
        defer { fixture.remove() }

        let cold = try await fixture.check()
        let warm = try await fixture.check()

        let first = try #require(cold.coverageCounts)
        let second = try #require(warm.coverageCounts)
        // Warns, Clean and the test file at least; module-level units on top where the build
        // system records them.
        #expect(first.units >= 3)
        #expect(first.compiled == first.units)
        #expect(first.read == 0)
        #expect(second.units == first.units)
        #expect(second.compiled == 0)
        #expect(second.read == second.units)
        #expect(cold.finding("build.diagnostic-coverage")?.severity == .note)
    }
}
