import Foundation
import Testing
import QualityGateCore
@testable import SafetyAuditor

/// Target types, read from the manifest rather than resolved from the network.
///
/// `TargetTypeMap.describe` ran `swift package describe`, which evaluates the manifest properly
/// — and therefore resolves and downloads the whole dependency graph. Surveying nine packages
/// wrote **2.7 GB** into repositories the operator does not own, for one question: is this file
/// in an executable, a library, a test, or a plugin?
///
/// The AST work never needed it. A package whose dependency is unresolvable still parses: the
/// checkers use `Parser.parse(source:)`, which reads text. Only the *severity refinement* wanted
/// the manifest, so the manifest is now read the way this tool reads every other Swift file.
@Suite("Manifest target parsing")
struct ManifestTargetParsingTests {

    private func fixture(_ manifest: String, dirs: [String] = []) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manifest.write(to: root.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)
        for dir in dirs {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        return root.path
    }

    @Test("A .target is a library")
    func targetIsLibrary() throws {
        let root = try fixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "Lib")])
        """)
        let map = TargetTypeMap.parsingManifest(packageRoot: root)
        #expect(map.targetType(forFile: "\(root)/Sources/Lib/File.swift") == .library)
    }

    @Test("An .executableTarget is an executable")
    func executableTarget() throws {
        let root = try fixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [.executableTarget(name: "Tool")])
        """)
        let map = TargetTypeMap.parsingManifest(packageRoot: root)
        #expect(map.targetType(forFile: "\(root)/Sources/Tool/main.swift") == .executable)
    }

    @Test("A .testTarget is a test")
    func testTarget() throws {
        let root = try fixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [.testTarget(name: "LibTests")])
        """)
        let map = TargetTypeMap.parsingManifest(packageRoot: root)
        #expect(map.targetType(forFile: "\(root)/Tests/LibTests/File.swift") == .test)
    }

    @Test("A .plugin target is a plugin")
    func pluginTarget() throws {
        let root = try fixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [.plugin(name: "Gate", capability: .command(intent: .custom(verb: "x", description: "y")))])
        """)
        let map = TargetTypeMap.parsingManifest(packageRoot: root)
        #expect(map.targetType(forFile: "\(root)/Plugins/Gate/Plugin.swift") == .plugin)
    }

    /// `.plugin` and `.library` appear in `products:` as well as `targets:`.
    ///
    /// This repository declares `.plugin(` twice and has exactly one plugin *target*. A scan
    /// that matched the call name anywhere in the file would report two, which is the reason
    /// this reads the syntax tree and walks only the `targets:` argument.
    @Test("Declarations in products are not targets")
    func productsAreNotTargets() throws {
        let root = try fixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "P",
            products: [
                .library(name: "Decoy", targets: ["Lib"]),
                .plugin(name: "DecoyPlugin", targets: ["Gate"]),
                .executable(name: "DecoyTool", targets: ["Lib"]),
            ],
            targets: [.target(name: "Lib")]
        )
        """)
        let map = TargetTypeMap.parsingManifest(packageRoot: root)
        #expect(map.targetType(forFile: "\(root)/Sources/Lib/File.swift") == .library)
        // The decoys named no real directory; nothing should have been invented for them.
        #expect(map.targetCount == 1, "products were counted as targets")
    }

    @Test("An explicit path: is honoured over the convention")
    func explicitPath() throws {
        let root = try fixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "Lib", path: "Custom/Place")])
        """)
        let map = TargetTypeMap.parsingManifest(packageRoot: root)
        #expect(map.targetType(forFile: "\(root)/Custom/Place/File.swift") == .library)
    }

    /// An unparseable manifest must not silently classify everything as executable.
    @Test("A malformed manifest falls back to the directory convention")
    func malformedFallsBackToConvention() throws {
        let root = try fixture("this is not swift {{{",
                               dirs: ["Sources/Lib", "Tests/LibTests", "Plugins/Gate"])
        let map = TargetTypeMap.parsingManifest(packageRoot: root)
        #expect(map.targetType(forFile: "\(root)/Sources/Lib/File.swift") == .library)
        #expect(map.targetType(forFile: "\(root)/Tests/LibTests/File.swift") == .test)
        #expect(map.targetType(forFile: "\(root)/Plugins/Gate/File.swift") == .plugin)
    }

    /// The whole point: no dependency resolution, no download, no `.build`.
    @Test("An unresolvable dependency does not prevent classification")
    func unresolvableDependencyIsIrrelevant() throws {
        let root = try fixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "P",
            dependencies: [.package(url: "https://example.invalid/nope.git", from: "1.0.0")],
            targets: [.testTarget(name: "LibTests")]
        )
        """)
        let map = TargetTypeMap.parsingManifest(packageRoot: root)
        #expect(map.targetType(forFile: "\(root)/Tests/LibTests/File.swift") == .test)
        #expect(!FileManager.default.fileExists(atPath: "\(root)/.build"),
                "classification must not resolve dependencies")
    }
}

/// The parsed map against what `swift package describe` reported for this package.
///
/// Recorded on 2026-08-18 from `describe --type json`: **125 targets — 61 library, 59 test,
/// 4 executable, 1 plugin**. The parser replaces that subprocess, so it has to agree with it,
/// and the agreement is the evidence that dropping the dependency resolution lost nothing.
///
/// Revised 2026-08-25 to **126 targets — 61 library, 60 test, 4 executable, 1 plugin**: the
/// `AccessibilityCLITests` target was added alongside the fix for the CLI accessibility
/// detector, which had no tests of its own. The drift is a target addition, which is the
/// benign half of what this count is watching for.
///
/// A separate suite because it reads the real repository rather than a fixture, and will need
/// updating when targets are added — which is the point: if the count drifts, either a target
/// was added or the parser stopped seeing a shape.
@Suite("Manifest parsing agrees with swift package describe")
struct ManifestParsingAgreementTests {

    private var repositoryRoot: String {
        // This file is Tests/SafetyAuditorTests/…; the package root is two levels up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    @Test("Every target kind is classified as describe classified it")
    func classificationsMatchDescribe() {
        let map = TargetTypeMap.parsingManifest(packageRoot: repositoryRoot)
        #expect(map.targetType(forFile: "\(repositoryRoot)/Sources/QualityGateCore/TrapPolicy.swift") == .library)
        #expect(map.targetType(forFile: "\(repositoryRoot)/Tests/SafetyAuditorTests/SafetyAuditorTests.swift") == .test)
        #expect(map.targetType(forFile: "\(repositoryRoot)/Sources/QualityGateCLI/QualityGateCLI.swift") == .executable)
        #expect(map.targetType(forFile: "\(repositoryRoot)/Plugins/QualityGatePlugin/QualityGatePlugin.swift") == .plugin)
    }

    @Test("The target count matches describe's 115")
    func countMatchesDescribe() {
        let map = TargetTypeMap.parsingManifest(packageRoot: repositoryRoot)
        // 127 until 2026-09-05, when IJSDashboardUI, ijs-dashboard-preview,
        // IJSDashboardApp and IJSDashboardUITests moved to quality-gate-dashboard.
        // 123 until 2026-09-18, when IJSSensor, IJSAggregator, IJSPolicyDiscovery,
        // IJSDashboardCore and their three test targets moved to
        // quality-gate-corpus-kit — step 1 of the judgment-layer split.
        // 116 until later the same day, when JudgmentWorkbench followed them — step 3,
        // which also took DashboardLoader to quality-gate-dashboard. Its test target
        // stays here and holds the golden re-audit half of the suite, so the count drops
        // by the one source target rather than by two.
        // The number is asserted rather than computed on purpose: it is a tripwire
        // for the parser silently disagreeing with `swift package describe`, so it
        // is expected to be edited whenever the manifest genuinely changes.
        #expect(map.targetCount == 115,
                "describe reported 115 targets on 2026-09-18; parser found \(map.targetCount)")
    }

    /// The decoy case, on the real manifest: `.plugin(` appears twice, once as a product.
    @Test("The real manifest's plugin product is not counted as a target")
    func realManifestPluginProductIsNotATarget() {
        let map = TargetTypeMap.parsingManifest(packageRoot: repositoryRoot)
        // Only Plugins/QualityGatePlugin is a plugin target; the product of the same family
        // names targets rather than declaring one.
        #expect(map.targetType(forFile: "\(repositoryRoot)/Sources/QualityGateCore/TrapPolicy.swift") != .plugin)
    }
}
