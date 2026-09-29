import Foundation
import Testing
import QualityGateCore
@testable import ShapeMetrics

/// The post-pass: turning a finished gate run into a snapshot on disk.
///
/// These are §5 tests 11–14 of `ARatioNeedsAPopulation.md`, less the parts that belong to the
/// CLI's own acceptance suite. What is asserted here is the pass's contract: it consumes results
/// it did not produce, says what it could not see, and writes bytes that do not change between
/// runs of an unchanged tree.
@Suite("ShapeMetricsPass")
struct ShapeMetricsPassTests {

    /// A package whose `Sources/` holds one module with a known shape.
    private func fixturePackage() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shape-pass-\(UUID().uuidString)")
        let module = root.appendingPathComponent("Sources/Fixture")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)

        // Ten source lines, two of which a rule will flag, and one branching function.
        let source = """
        // a comment, which is not a source line
        func classify(_ value: Int) -> String {
            if value > 0 {
                return "positive"
            }
            return "other"
        }
        """
        try source.write(
            to: module.appendingPathComponent("Fixture.swift"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    private func result(_ checkerId: String, _ diagnostics: [Diagnostic] = []) -> CheckResult {
        CheckResult(
            checkerId: checkerId,
            status: .passed,
            diagnostics: diagnostics,
            duration: .seconds(0)
        )
    }

    private func allContributorsRan(file: String) -> [CheckResult] {
        [
            result("idiom", [
                Diagnostic(severity: .note, message: "m", filePath: file, lineNumber: 2,
                           ruleId: "idiom.empty-count", endLine: 2),
            ]),
            result("smells"),
            result("duplication"),
        ]
    }

    // MARK: - 11. The pass consumes what the run produced

    @Test("The contributing checkers are the three whose line sets the union needs")
    func contributorsAreTheUnionsInputs() {
        #expect(ShapeMetrics.contributingCheckers == ["idiom", "smells", "duplication"])
    }

    @Test("A snapshot is produced when every contributor ran")
    func snapshotIsProduced() throws {
        let root = try fixturePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Fixture/Fixture.swift").path

        let snapshot = try #require(ShapeMetricsPass.run(
            results: allContributorsRan(file: file),
            projectRoot: root,
            projectID: "fixture"
        ))
        #expect(snapshot.projectID == "fixture")
        #expect(snapshot.schema == ShapeSnapshot.currentSchema)
        #expect(snapshot.report.coverage.isComplete)

        let verbosity = try #require(snapshot.report.verbosity)
        // The comment is not a source line, so it is in neither numerator nor denominator.
        #expect(verbosity.sloc == 6)
        #expect(abs(verbosity.verbosity - 1.0 / 6.0) < 1e-9)

        // One function, with one `if`: cyclomatic 2, under the default threshold of 10.
        let erosion = try #require(snapshot.report.erosion)
        #expect(erosion.functionCount == 1)
        #expect(erosion.functionsOverThreshold == 0)
        #expect(abs(erosion.erosion) < 1e-9)
    }

    @Test("The pass applies the threshold it is given, not the default")
    func passHonoursItsThreshold() throws {
        // The fixture's one function is cyclomatic 2. At the default threshold of 10 it is not
        // eroded; at 1 it is. This is what `--shape-cc-threshold` reaches, and the wiring is
        // asserted here rather than at the parser, which has no test target of its own.
        let root = try fixturePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Fixture/Fixture.swift").path

        let lenient = try #require(ShapeMetricsPass.run(
            results: allContributorsRan(file: file),
            projectRoot: root, projectID: "fixture", threshold: 10))
        let strict = try #require(ShapeMetricsPass.run(
            results: allContributorsRan(file: file),
            projectRoot: root, projectID: "fixture", threshold: 1))

        let lenientErosion = try #require(lenient.report.erosion)
        let strictErosion = try #require(strict.report.erosion)

        #expect(lenientErosion.functionsOverThreshold == 0)
        #expect(strictErosion.functionsOverThreshold == 1)
        #expect(lenientErosion.threshold == 10)
        #expect(strictErosion.threshold == 1)
        // The same tree measured two ways: only the threshold differs, and the answer does too.
        #expect(strictErosion.erosion > lenientErosion.erosion)
    }

    @Test("A checker that did not run is named, and the headline is withheld")
    func missingContributorIsNamed() throws {
        let root = try fixturePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try #require(ShapeMetricsPass.run(
            results: [result("idiom"), result("smells")],
            projectRoot: root,
            projectID: "fixture"
        ))
        #expect(snapshot.report.verbosity == nil)
        #expect(snapshot.report.coverage.missingCheckers == ["duplication"])
        // Erosion does not depend on the union, so it is still there to read.
        let erosion = try #require(snapshot.report.erosion)
        #expect(erosion.functionCount == 1)
    }

    @Test("A package with no Swift source yields no snapshot, rather than a snapshot of zero")
    func emptyPackageYieldsNoSnapshot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shape-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ShapeMetricsPass.run(
            results: allContributorsRan(file: "/nowhere.swift"),
            projectRoot: root,
            projectID: "empty"
        ) == nil)
    }

    // MARK: - 12. The artifact

    @Test("The snapshot round-trips through its JSON artifact")
    func snapshotRoundTrips() throws {
        let root = try fixturePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Fixture/Fixture.swift").path

        let snapshot = try #require(ShapeMetricsPass.run(
            results: allContributorsRan(file: file),
            projectRoot: root,
            projectID: "fixture"
        ))
        let out = root.appendingPathComponent("artifacts/shape.json").path
        try ShapeMetricsPass.write(snapshot, to: out)

        let data = try Data(contentsOf: URL(fileURLWithPath: out))
        let decoded = try JSONDecoder().decode(ShapeSnapshot.self, from: data)
        #expect(decoded == snapshot)

        // Components travel with the headline: a bare ratio cannot be acted on.
        let text = String(decoding: data, as: UTF8.self)
        for key in ["verbosity", "overlap", "byRule", "countShare", "concentration", "coverage"] {
            #expect(text.contains(key), "\(key) missing from the artifact")
        }
    }

    @Test("Writing creates the parent directory rather than failing on it")
    func writeCreatesParentDirectories() throws {
        let root = try fixturePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Fixture/Fixture.swift").path

        let snapshot = try #require(ShapeMetricsPass.run(
            results: allContributorsRan(file: file),
            projectRoot: root,
            projectID: "fixture"
        ))
        let nested = root.appendingPathComponent("a/b/c/shape.json").path
        try ShapeMetricsPass.write(snapshot, to: nested)
        #expect(FileManager.default.fileExists(atPath: nested))
    }

    // MARK: - 13. Determinism

    @Test("Two runs over an unchanged tree produce identical snapshots")
    func runsAreDeterministic() throws {
        let root = try fixturePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Fixture/Fixture.swift").path

        let first = try #require(ShapeMetricsPass.run(
            results: allContributorsRan(file: file), projectRoot: root, projectID: "fixture"))
        let second = try #require(ShapeMetricsPass.run(
            results: allContributorsRan(file: file), projectRoot: root, projectID: "fixture"))
        #expect(first == second)
    }

    @Test("The artifact is byte-identical between runs")
    func artifactIsByteIdentical() throws {
        let root = try fixturePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Fixture/Fixture.swift").path

        let snapshot = try #require(ShapeMetricsPass.run(
            results: allContributorsRan(file: file), projectRoot: root, projectID: "fixture"))

        let first = root.appendingPathComponent("first.json").path
        let second = root.appendingPathComponent("second.json").path
        try ShapeMetricsPass.write(snapshot, to: first)
        try ShapeMetricsPass.write(snapshot, to: second)

        // Sorted keys are what make this true. An unsorted encoder emits a different byte
        // order per process, which would make a corpus diff noise rather than signal.
        #expect(try Data(contentsOf: URL(fileURLWithPath: first))
                == Data(contentsOf: URL(fileURLWithPath: second)))
    }

    @Test("File order does not depend on how the file system enumerated")
    func fileOrderIsStable() throws {
        let root = try fixturePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let module = root.appendingPathComponent("Sources/Fixture")
        for name in ["Zeta.swift", "Alpha.swift", "Mid.swift"] {
            try "let \(name.prefix(3).lowercased()) = 1\n".write(
                to: module.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let files = ShapeMetricsPass.swiftFiles(under: root.appendingPathComponent("Sources"))
        #expect(files == files.sorted())
    }

    // MARK: - 14. Scope

    @Test("Tests/ is not measured — the denominator is Sources/ only")
    func testsAreNotMeasured() throws {
        let root = try fixturePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let testsDir = root.appendingPathComponent("Tests/FixtureTests")
        try FileManager.default.createDirectory(at: testsDir, withIntermediateDirectories: true)
        try (1...50).map { "let unused\($0) = \($0)" }.joined(separator: "\n").write(
            to: testsDir.appendingPathComponent("FixtureTests.swift"),
            atomically: true, encoding: .utf8)

        let file = root.appendingPathComponent("Sources/Fixture/Fixture.swift").path
        let snapshot = try #require(ShapeMetricsPass.run(
            results: allContributorsRan(file: file), projectRoot: root, projectID: "fixture"))

        // Still the six source lines of the one module; the fifty test lines would have
        // diluted the ratio by a factor of nine.
        let verbosity = try #require(snapshot.report.verbosity)
        #expect(verbosity.sloc == 6)
    }

    @Test("A module name is the first path component under Sources/")
    func moduleNamesComeFromThePath() {
        let name = ShapeMetricsPass.moduleName(
            of: "/pkg/Sources/Fixture/Nested/File.swift",
            under: "/pkg/Sources"
        )
        #expect(name == "Fixture")
    }
}
