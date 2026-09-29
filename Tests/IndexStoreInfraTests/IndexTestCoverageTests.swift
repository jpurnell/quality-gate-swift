import Foundation
import Testing
@testable import IndexStoreInfra

/// An index built without the test targets makes every symbol only tests call look dead.
///
/// `swift build` compiles the library alone, so unless the index build asks for `--build-tests`
/// the units for a test suite are simply absent. Reachability read against that store is not
/// merely incomplete — it is confidently wrong in one direction, and the finding it produces
/// ("unreachable from any entry point") is indistinguishable from a real one. Found on
/// SwiftXLSX's CI, where a parser method six tests call was reported as dead against a
/// 182-unit index while the same commit passed locally against a 453-unit one.
@Suite("Index test coverage")
struct IndexTestCoverageTests {

    /// A package with `Tests/<Suite>/<File>.swift`, and a store holding the named units.
    private static func fixture(
        testFiles: [String], unitNames: [String], createUnitsDirectory: Bool = true
    ) throws -> (root: URL, store: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("itc-\(UUID().uuidString)")
        let manager = FileManager.default

        if !testFiles.isEmpty {
            let suite = root.appendingPathComponent("Tests/AlphaTests", isDirectory: true)
            try manager.createDirectory(at: suite, withIntermediateDirectories: true)
            for file in testFiles {
                try "// test\n".write(
                    to: suite.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        } else {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let store = root.appendingPathComponent(".build/index-build/index-store", isDirectory: true)
        if createUnitsDirectory {
            let units = StoreLocator.unitsDirectory(in: store)
            try manager.createDirectory(at: units, withIntermediateDirectories: true)
            for name in unitNames {
                try "unit\n".write(
                    to: units.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        return (root, store)
    }

    @Test("A store holding a unit for a test source reports test coverage")
    func testUnitsPresent() throws {
        let (root, store) = try Self.fixture(
            testFiles: ["ParserTests.swift"],
            unitNames: ["Parser.swift.o-A1B2", "ParserTests.swift.o-C3D4"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(IndexTestCoverage.includesTestUnits(store: store, packageRoot: root) == true)
    }

    @Test("A store holding only library units reports no test coverage")
    func testUnitsAbsent() throws {
        let (root, store) = try Self.fixture(
            testFiles: ["ParserTests.swift"],
            unitNames: ["Parser.swift.o-A1B2", "Workbook.swift.o-C3D4"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(IndexTestCoverage.includesTestUnits(store: store, packageRoot: root) == false)
    }

    @Test("A package with no test sources leaves the question unanswered")
    func noTestsIsNil() throws {
        let (root, store) = try Self.fixture(testFiles: [], unitNames: ["Parser.swift.o-A1B2"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(IndexTestCoverage.includesTestUnits(store: store, packageRoot: root) == nil)
    }

    @Test("A store with no units directory leaves the question unanswered")
    func noUnitsDirectoryIsNil() throws {
        let (root, store) = try Self.fixture(
            testFiles: ["ParserTests.swift"], unitNames: [], createUnitsDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(IndexTestCoverage.includesTestUnits(store: store, packageRoot: root) == nil)
    }
}
