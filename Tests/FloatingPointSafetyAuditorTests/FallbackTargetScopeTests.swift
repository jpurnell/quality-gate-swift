import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

/// Writes `files` under a fresh root and returns the root.
private func makeTree(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fallback-scope-\(UUID().uuidString)")
    for (relativePath, contents) in files {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

private let unguardedConversion = """
func year(tenor: Double) -> Int {
    return Int(tenor)
}

"""

private let conventionalManifest = """
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Curves",
    targets: [
        .target(name: "Curves"),
        .testTarget(name: "CurvesTests", dependencies: ["Curves"]),
    ]
)

"""

private func configuration(at root: URL) -> Configuration {
    var configuration = Configuration()
    configuration.projectRoot = root
    return configuration
}

/// The package-relative paths `fallback.int-conversion-unguarded` reports under `root`.
private func unguardedFiles(in result: CheckResult, root: URL) -> [String] {
    // Cut at the root's own directory name: the temporary directory is reached through a
    // symlink on macOS, so the two absolute spellings of one file need not share a prefix.
    let marker = "/" + root.lastPathComponent + "/"
    return result.diagnostics
        .filter { $0.ruleId == FallbackRuleID.intConversionUnguarded }
        .compactMap(\.filePath)
        .map { path in
            guard let range = path.range(of: marker) else { return path }
            return String(path[range.upperBound...])
        }
        .sorted()
}

private func coverageMessage(of result: CheckResult) -> String {
    result.diagnostics.first { $0.ruleId == FallbackRuleID.coverage }?.message ?? ""
}

// MARK: - Tests

// BusinessMath keeps reference scripts under `project/reference/`, one of them a
// Markdown code fence saved with a `.swift` extension. Neither is in a target, neither
// is compiled, and seven conversions in one of them were baselined as though they
// shipped.

@Suite("fallback: only what a target compiles is audited")
struct FallbackTargetScopeTests {

    @Test("A file in a target is audited; a script outside every target is counted, not audited")
    func auditsTargetsAndCountsTheRest() async throws {
        let root = try makeTree([
            "Package.swift": conventionalManifest,
            "Sources/Curves/Curve.swift": unguardedConversion,
            "project/reference/marginal_var_example.swift": unguardedConversion,
            "project/reference/NewtonRaphson_ALT.swift": "```swift\nlet x = Int(1.5)\n```\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["Sources/Curves/Curve.swift"])
        #expect(result.status == .failed)
        let coverage = coverageMessage(of: result)
        // The manifest and the one target file.
        #expect(coverage.contains("examined 2 files"))
        #expect(coverage.contains("2 .swift files outside any SwiftPM target not audited"))
    }

    @Test("One file outside a target is `1 .swift file`")
    func countsOneFileInTheSingular() async throws {
        let root = try makeTree([
            "Package.swift": conventionalManifest,
            "Sources/Curves/Curve.swift": "let answer = 42\n",
            "Examples/demo.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == [])
        #expect(result.status == .passed)
        #expect(coverageMessage(of: result).contains("1 .swift file outside any SwiftPM target not audited"))
    }

    @Test("With every file in a target the note says nothing about targets")
    func saysNothingWhenNothingIsSkipped() async throws {
        let root = try makeTree([
            "Package.swift": conventionalManifest,
            "Sources/Curves/Curve.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["Sources/Curves/Curve.swift"])
        #expect(!coverageMessage(of: result).contains("outside any SwiftPM target"))
    }

    @Test("No Package.swift: every file is audited, as before")
    func auditsEverythingWithoutAManifest() async throws {
        let root = try makeTree([
            "App/Model.swift": unguardedConversion,
            "project/reference/marginal_var_example.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == [
            "App/Model.swift",
            "project/reference/marginal_var_example.swift",
        ])
        let coverage = coverageMessage(of: result)
        #expect(coverage.contains("examined 2 files"))
        #expect(!coverage.contains("outside any SwiftPM target"))
    }

    @Test("A target with an explicit path: is a target wherever it lives")
    func auditsExplicitTargetPath() async throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Companion",
            targets: [
                .target(name: "Core"),
                .target(name: "Exercises_Chapter1", dependencies: ["Core"], path: "Exercises/Chapter1"),
            ]
        )

        """
        let root = try makeTree([
            "Package.swift": manifest,
            "Exercises/Chapter1/Exercise1.swift": unguardedConversion,
            "Exercises/Scratch/Notes.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["Exercises/Chapter1/Exercise1.swift"])
        #expect(coverageMessage(of: result).contains("1 .swift file outside any SwiftPM target not audited"))
    }

    @Test("A target path that is not a literal cannot be read, so nothing is skipped")
    func auditsEverythingWhenAPathIsComputed() async throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let exercises = "Exercises/Chapter1"
        let package = Package(
            name: "Companion",
            targets: [
                .target(name: "Core"),
                .target(name: "Exercises_Chapter1", path: exercises),
            ]
        )

        """
        let root = try makeTree([
            "Package.swift": manifest,
            "Exercises/Chapter1/Exercise1.swift": unguardedConversion,
            "Notes/Scratch.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == [
            "Exercises/Chapter1/Exercise1.swift",
            "Notes/Scratch.swift",
        ])
        let coverage = coverageMessage(of: result)
        #expect(!coverage.contains("outside any SwiftPM target"))
        #expect(coverage.contains("target paths in Package.swift could not be read, so every file was audited"))
    }

    @Test("BusinessMath's manifest: targets built in a variable and appended to are still read")
    func readsTargetsBuiltInAVariable() async throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        var targets: [Target] = [
            .target(name: "BusinessMath", dependencies: [.target(name: "TestSupport")]),
            .target(name: "TestSupport", path: "Tests/TestSupport"),
        ]
        #if !os(Linux)
        targets += [
            .target(name: "BusinessMathDSL", path: "DSL"),
        ]
        #endif
        let package = Package(name: "BusinessMath", targets: targets)

        """
        let root = try makeTree([
            "Package.swift": manifest,
            "Sources/BusinessMath/Curve.swift": unguardedConversion,
            "DSL/Builder.swift": unguardedConversion,
            "project/reference/marginal_var_example.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == [
            "DSL/Builder.swift",
            "Sources/BusinessMath/Curve.swift",
        ])
        let coverage = coverageMessage(of: result)
        #expect(coverage.contains("1 .swift file outside any SwiftPM target not audited"))
        #expect(!coverage.contains("could not be read"))
    }

    @Test("A target outside the package directory cannot be scoped, so nothing is skipped")
    func auditsEverythingWhenATargetLeavesThePackage() async throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Companion",
            targets: [.target(name: "Shared", path: "../Shared/Sources")]
        )

        """
        let root = try makeTree([
            "Package.swift": manifest,
            "Notes/Scratch.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["Notes/Scratch.swift"])
        #expect(coverageMessage(of: result).contains("target paths in Package.swift could not be read, so every file was audited"))
    }

    @Test("A target rooted at the package directory owns every file")
    func auditsEverythingForARootTarget() async throws {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Flat",
            targets: [.target(name: "Flat", path: ".")]
        )

        """
        let root = try makeTree([
            "Package.swift": manifest,
            "Model/Curve.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["Model/Curve.swift"])
        #expect(!coverageMessage(of: result).contains("outside any SwiftPM target"))
    }

    @Test("Beside an Xcode project a file may be in an Xcode target, and is still audited")
    func auditsFilesBesideAnXcodeProject() async throws {
        let root = try makeTree([
            "Package.swift": conventionalManifest,
            "Sources/Curves/Curve.swift": "let answer = 42\n",
            "App/PanLANApp.xcodeproj/project.pbxproj": "// !$*UTF8*$!\n",
            "App/PanLANApp/Model.swift": unguardedConversion,
            "Notes/Scratch.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["App/PanLANApp/Model.swift"])
        #expect(coverageMessage(of: result).contains("1 .swift file outside any SwiftPM target not audited"))
    }

    @Test("An Xcode project at the package root claims the whole tree")
    func auditsEverythingBesideARootXcodeProject() async throws {
        let root = try makeTree([
            "Package.swift": conventionalManifest,
            "Applesoft.xcodeproj/project.pbxproj": "// !$*UTF8*$!\n",
            "Views/Screen.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["Views/Screen.swift"])
        #expect(!coverageMessage(of: result).contains("outside any SwiftPM target"))
    }

    @Test("Test code outside a target is test code, and is not counted as skipped production code")
    func doesNotCountTestFiles() async throws {
        let root = try makeTree([
            "Package.swift": conventionalManifest,
            "Sources/Curves/Curve.swift": "let answer = 42\n",
            "Tests/CurvesTests/CurveTests.swift": unguardedConversion,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == [])
        #expect(!coverageMessage(of: result).contains("outside any SwiftPM target"))
    }
}

// MARK: - Reading the manifest

@Suite("FallbackTargetScope: which directories a manifest's targets own")
struct FallbackTargetScopeManifestTests {

    private static let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "Companion",
        dependencies: [.package(path: "../Sibling")],
        targets: [
            .target(name: "Core", dependencies: [.target(name: "Support")]),
            .target(name: "Support", path: "Support/Code/"),
            .binaryTarget(name: "Blob", path: "Vendor/Blob.xcframework"),
        ]
    )

    """

    @Test("Ownership is decided on whole path components")
    func ownsWholeComponents() {
        let scope = FallbackTargetScope(manifestSource: Self.manifest)

        #expect(scope.owns("Sources/Core/Curve.swift"))
        #expect(scope.owns("Support/Code/Helper.swift"))
        #expect(scope.owns("Support/Code/Nested/Deep.swift"))
        #expect(scope.owns("Package.swift"))
        #expect(scope.owns("Package@swift-5.9.swift"))
        // `Sources2` begins with `Sources` and is not `Sources`.
        #expect(!scope.owns("Sources2/Core/Curve.swift"))
        #expect(!scope.owns("Support/Codex/Helper.swift"))
        #expect(!scope.owns("Support/Notes.swift"))
        #expect(!scope.owns("project/reference/script.swift"))
        #expect(!scope.owns("CV.swift"))
    }

    @Test("A dependency's path: and a binary target's path: are not source directories")
    func ignoresPathsThatHoldNoSource() {
        let scope = FallbackTargetScope(manifestSource: Self.manifest)

        // `.package(path: "../Sibling")` leaves the package directory; were it read as a
        // target's path the whole manifest would be unreadable and nothing skipped.
        #expect(scope.resolution != .unreadable)
        #expect(!scope.owns("Vendor/Blob.xcframework/Headers/Blob.swift"))
    }

    @Test("With no manifest every path is owned")
    func ownsEverythingWithoutAManifest() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallback-scope-absent-\(UUID().uuidString)")
        let scope = FallbackTargetScope.resolve(projectRoot: root)

        #expect(scope.resolution == .noManifest)
        #expect(scope.owns("project/reference/script.swift"))
    }
}

// MARK: - Range constants declared in another file

@Suite("fallback: a range constant is the same constant in every file of the project")
struct FallbackCrossFileRangeTests {

    private static let distributions = """
    enum BuiltinStatisticalDistributions {
        /// Excel's ceiling on degrees of freedom.
        static let degreesOfFreedomRange: Range<Double> = 1..<1e10
    }

    """

    private static let statistics = """
    enum BuiltinSpreadsheetStatistics {
        static func chiSquareInverse(p: Double, df: Double) -> Int? {
            guard p >= 0, p <= 1,
                  BuiltinStatisticalDistributions.degreesOfFreedomRange.contains(df)
            else { return nil }
            return Int(df.rounded(.towardZero))
        }
    }

    """

    @Test("SwiftExcelFunctions CHISQ.INV: the range is declared in a sibling file")
    func acceptsRangeConstantFromAnotherFile() async throws {
        let root = try makeTree([
            "Sources/Excel/BuiltinStatisticalDistributions.swift": Self.distributions,
            "Sources/Excel/BuiltinSpreadsheetStatistics.swift": Self.statistics,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == [])
        #expect(coverageMessage(of: result).contains("1 integer conversion"))
    }

    @Test("With no such constant anywhere, the membership test bounds nothing")
    func flagsWhenTheConstantIsNotDeclared() async throws {
        let root = try makeTree([
            "Sources/Excel/BuiltinSpreadsheetStatistics.swift": Self.statistics,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["Sources/Excel/BuiltinSpreadsheetStatistics.swift"])
    }

    @Test("A second declaration of the name that is not a constant range withdraws it everywhere")
    func flagsWhenAnotherDeclarationDisagrees() async throws {
        let other = """
        struct Workbook {
            var degreesOfFreedomRange = Workbook.computeRange()
            static func computeRange() -> ClosedRange<Double> { 0...Double.infinity }
        }

        """
        let root = try makeTree([
            "Sources/Excel/BuiltinStatisticalDistributions.swift": Self.distributions,
            "Sources/Excel/BuiltinSpreadsheetStatistics.swift": Self.statistics,
            "Sources/Excel/Workbook.swift": other,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["Sources/Excel/BuiltinSpreadsheetStatistics.swift"])
    }

    @Test("A constant with an infinite bound in another file bounds nothing here")
    func flagsInfiniteRangeFromAnotherFile() async throws {
        let unbounded = """
        enum BuiltinStatisticalDistributions {
            static let degreesOfFreedomRange: PartialRangeFrom<Double> = 1...
        }

        """
        let root = try makeTree([
            "Sources/Excel/BuiltinStatisticalDistributions.swift": unbounded,
            "Sources/Excel/BuiltinSpreadsheetStatistics.swift": Self.statistics,
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(unguardedFiles(in: result, root: root) == ["Sources/Excel/BuiltinSpreadsheetStatistics.swift"])
    }
}
