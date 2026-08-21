// swift-tools-version: 6.2
// legibility:description: Modular, AST-powered static analysis for Swift projects.
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "quality-gate-swift",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Core library with shared protocol and models
        .library(
            name: "QualityGateCore",
            targets: ["QualityGateCore"]
        ),
        // Individual checker modules
        .library(
            name: "SafetyAuditor",
            targets: ["SafetyAuditor"]
        ),
        .library(
            name: "BuildChecker",
            targets: ["BuildChecker"]
        ),
        .library(
            name: "TestRunner",
            targets: ["TestRunner"]
        ),
        .library(
            name: "DocLinter",
            targets: ["DocLinter"]
        ),
        .library(
            name: "DocCodeAuditor",
            targets: ["DocCodeAuditor"]
        ),
        .library(
            name: "DocGeneratedAuditor",
            targets: ["DocGeneratedAuditor"]
        ),
        .library(
            name: "DocCoverageChecker",
            targets: ["DocCoverageChecker"]
        ),
        .library(
            name: "DiskCleaner",
            targets: ["DiskCleaner"]
        ),
        .library(
            name: "UnreachableCodeAuditor",
            targets: ["UnreachableCodeAuditor"]
        ),
        .library(
            name: "RecursionAuditor",
            targets: ["RecursionAuditor"]
        ),
        .library(
            name: "ConcurrencyAuditor",
            targets: ["ConcurrencyAuditor"]
        ),
        .library(
            name: "PointerEscapeAuditor",
            targets: ["PointerEscapeAuditor"]
        ),
        .library(
            name: "MemoryBuilder",
            targets: ["MemoryBuilder"]
        ),
        .library(
            name: "AccessibilityAuditor",
            targets: ["AccessibilityAuditor"]
        ),
        .library(
            name: "StatusAuditor",
            targets: ["StatusAuditor"]
        ),
        .library(
            name: "SwiftVersionChecker",
            targets: ["SwiftVersionChecker"]
        ),
        .library(
            name: "LoggingAuditor",
            targets: ["LoggingAuditor"]
        ),
        .library(
            name: "TestQualityAuditor",
            targets: ["TestQualityAuditor"]
        ),
        .library(
            name: "ContextAuditor",
            targets: ["ContextAuditor"]
        ),
        .library(
            name: "DependencyAuditor",
            targets: ["DependencyAuditor"]
        ),
        .library(
            name: "SubmoduleAuditor",
            targets: ["SubmoduleAuditor"]
        ),
        .library(
            name: "ReleaseReadinessAuditor",
            targets: ["ReleaseReadinessAuditor"]
        ),
        .library(
            name: "FloatingPointSafetyAuditor",
            targets: ["FloatingPointSafetyAuditor"]
        ),
        .library(
            name: "StochasticDeterminismAuditor",
            targets: ["StochasticDeterminismAuditor"]
        ),
        .library(
            name: "TemporalDeterminismAuditor",
            targets: ["TemporalDeterminismAuditor"]
        ),
        .library(
            name: "GPUSafetyAuditor",
            targets: ["GPUSafetyAuditor"]
        ),
        .library(
            name: "BoundedIOAuditor",
            targets: ["BoundedIOAuditor"]
        ),
        .library(
            name: "LivenessAuditor",
            targets: ["LivenessAuditor"]
        ),
        .library(
            name: "MemoryLifecycleGuard",
            targets: ["MemoryLifecycleGuard"]
        ),
        .library(
            name: "MCPReadinessAuditor",
            targets: ["MCPReadinessAuditor"]
        ),
        .library(
            name: "ProcessSafetyAuditor",
            targets: ["ProcessSafetyAuditor"]
        ),
        .library(
            name: "ComplexityAnalyzer",
            targets: ["ComplexityAnalyzer"]
        ),
        .library(
            name: "LegibilityAnalyzer",
            targets: ["LegibilityAnalyzer"]
        ),
        .library(
            name: "HIGAuditor",
            targets: ["HIGAuditor"]
        ),
        .library(
            name: "IndexStoreInfra",
            targets: ["IndexStoreInfra"]
        ),
        .library(
            name: "AppIntentsAuditor",
            targets: ["AppIntentsAuditor"]
        ),
        .library(
            name: "XcodeBuildChecker",
            targets: ["XcodeBuildChecker"]
        ),
        .library(
            name: "QualityGateTestKit",
            targets: ["QualityGateTestKit"]
        ),
        // IJS modules
        .library(
            name: "IJSSensor",
            targets: ["IJSSensor"]
        ),
        .library(
            name: "IJSAggregator",
            targets: ["IJSAggregator"]
        ),
        .library(
            name: "IJSRefiner",
            targets: ["IJSRefiner"]
        ),
        .library(
            name: "IJSPolicyDiscovery",
            targets: ["IJSPolicyDiscovery"]
        ),
        .library(
            name: "ConsistencyChecker",
            targets: ["ConsistencyChecker"]
        ),
        // Major-points parity (Phase 4c)
        .library(
            name: "IdiomAuditor",
            targets: ["IdiomAuditor"]
        ),
        // Judgment workbench (Phase 3a §7) + trust service core (Phase 3b)
        .library(
            name: "JudgmentWorkbench",
            targets: ["JudgmentWorkbench"]
        ),
        .library(
            name: "CorpusService",
            targets: ["CorpusService"]
        ),
        .library(
            name: "DuplicationAuditor",
            targets: ["DuplicationAuditor"]
        ),
        .library(
            name: "SmellPack",
            targets: ["SmellPack"]
        ),
        .library(
            name: "KeychainSecretsChecker",
            targets: ["KeychainSecretsChecker"]
        ),
        .library(
            name: "PrivacyManifestChecker",
            targets: ["PrivacyManifestChecker"]
        ),
        .library(
            name: "ControlMapping",
            targets: ["ControlMapping"]
        ),
        // Dashboard
        .library(
            name: "IJSDashboardCore",
            targets: ["IJSDashboardCore"]
        ),
        // CLI executable
        .executable(
            name: "quality-gate",
            targets: ["QualityGateCLI"]
        ),
        // Native dashboard app (macOS)
        .executable(
            name: "IJSDashboardApp",
            targets: ["IJSDashboardApp"]
        ),
        // IJS MCP Server
        .executable(
            name: "ijs-mcp-server",
            targets: ["IJSMCPServer"]
        ),
        // SPM Command Plugin
        .plugin(
            name: "QualityGatePlugin",
            targets: ["QualityGatePlugin"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/apple/indexstore-db.git", branch: "main"),
        .package(url: "https://github.com/jpurnell/quality-gate-types.git", from: "1.4.0"),
        .package(url: "https://github.com/jpurnell/swift-vigil.git", from: "0.6.0"),
        .package(url: "git@github.com:jpurnell/quality-gate-corpus-kit.git", from: "1.14.0"),
		.package(url: "https://github.com/jpurnell/BusinessMath", from: "2.3.1"),
        .package(url: "https://github.com/jpurnell/BusinessMath-UI", from: "0.5.0"),
        .package(url: "https://github.com/jpurnell/BusinessMath-Adapters", from: "0.4.1"),
        .package(url: "https://github.com/jpurnell/SwiftCLIKit.git", from: "1.3.1"),
        .package(url: "https://github.com/jpurnell/SwiftMCPServer.git", from: "1.1.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // MARK: - Core Module
        .target(
            name: "QualityGateCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
                .product(name: "VigilKit", package: "swift-vigil"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            exclude: ["QualityGateCore.docc"]
        ),
        .testTarget(
            name: "QualityGateCoreTests",
            dependencies: ["QualityGateCore"]
        ),

        // MARK: - Checker Modules
        .target(
            name: "SafetyAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["SafetyAuditor.docc"]
        ),
        .testTarget(
            name: "SafetyAuditorTests",
            dependencies: [
                "IndexStoreInfra","SafetyAuditor"]
        ),

        .target(
            name: "BuildChecker",
            dependencies: ["QualityGateCore", "IndexStoreInfra"],
            exclude: ["BuildChecker.docc"]
        ),
        .testTarget(
            name: "BuildCheckerTests",
            dependencies: ["BuildChecker", "IndexStoreInfra"]
        ),

        .target(
            name: "TestRunner",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["TestRunner.docc"]
        ),
        .testTarget(
            name: "TestRunnerTests",
            dependencies: ["TestRunner", "IndexStoreInfra"]
        ),

        .target(
            name: "DocLinter",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["DocLinter.docc"]
        ),
        .testTarget(
            name: "DocLinterTests",
            dependencies: [
                "IndexStoreInfra","DocLinter"]
        ),

        .target(
            name: "DocCodeAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["DocCodeAuditor.docc"]
        ),
        .testTarget(
            name: "DocCodeAuditorTests",
            dependencies: ["DocCodeAuditor"]
        ),

        .target(
            name: "DocGeneratedAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["DocGeneratedAuditor.docc"]
        ),
        .testTarget(
            name: "DocGeneratedAuditorTests",
            dependencies: ["DocGeneratedAuditor"]
        ),

        .target(
            name: "DocCoverageChecker",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["DocCoverageChecker.docc"]
        ),
        .testTarget(
            name: "DocCoverageCheckerTests",
            dependencies: ["DocCoverageChecker"]
        ),

        .target(
            name: "DiskCleaner",
            dependencies: ["QualityGateCore"],
            exclude: ["DiskCleaner.docc"]
        ),
        .testTarget(
            name: "DiskCleanerTests",
            dependencies: ["DiskCleaner"]
        ),

        .target(
            name: "UnreachableCodeAuditor",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            exclude: ["UnreachableCodeAuditor.docc"]
        ),
        .testTarget(
            name: "UnreachableCodeAuditorTests",
            dependencies: ["UnreachableCodeAuditor"],
            exclude: ["Fixtures"]
        ),

        .target(
            name: "RecursionAuditor",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["RecursionAuditor.docc"]
        ),
        .testTarget(
            name: "RecursionAuditorTests",
            dependencies: ["RecursionAuditor"]
        ),

        .target(
            name: "ConcurrencyAuditor",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["ConcurrencyAuditor.docc"]
        ),
        .testTarget(
            name: "ConcurrencyAuditorTests",
            dependencies: ["ConcurrencyAuditor"]
        ),

        .target(
            name: "PointerEscapeAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["PointerEscapeAuditor.docc"]
        ),
        .testTarget(
            name: "PointerEscapeAuditorTests",
            dependencies: [
                "IndexStoreInfra","PointerEscapeAuditor"]
        ),

        .target(
            name: "MemoryBuilder",
            dependencies: [
                "QualityGateCore",
                .product(name: "Yams", package: "Yams"),
            ],
            exclude: ["MemoryBuilder.docc"]
        ),
        .testTarget(
            name: "MemoryBuilderTests",
            dependencies: ["MemoryBuilder"]
        ),

        .target(
            name: "AccessibilityCore",
            dependencies: ["QualityGateCore"]
        ),
        .testTarget(
            name: "AccessibilityCoreTests",
            dependencies: ["AccessibilityCore"]
        ),
        .target(
            name: "AccessibilitySwiftUI",
            dependencies: [
                "AccessibilityCore",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "AccessibilityCLI",
            dependencies: [
                "AccessibilityCore",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "AccessibilityAuditor",
            dependencies: [
                "IndexStoreInfra",
                "AccessibilityCore",
                "AccessibilitySwiftUI",
                "AccessibilityCLI",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["ACCESSIBILITY_MATRIX.md", "AccessibilityAuditor.docc"]
        ),
        .testTarget(
            name: "AccessibilityAuditorTests",
            dependencies: [
                "IndexStoreInfra","AccessibilityAuditor"]
        ),

        .target(
            name: "StatusAuditor",
            dependencies: ["QualityGateCore"],
            exclude: ["StatusAuditor.docc"]
        ),
        .testTarget(
            name: "StatusAuditorTests",
            dependencies: ["StatusAuditor"]
        ),

        .target(
            name: "SwiftVersionChecker",
            dependencies: ["QualityGateCore"],
            exclude: ["SwiftVersionChecker.docc"]
        ),
        .testTarget(
            name: "SwiftVersionCheckerTests",
            dependencies: ["SwiftVersionChecker"]
        ),

        .target(
            name: "LoggingAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["LoggingAuditor.docc"]
        ),
        .testTarget(
            name: "LoggingAuditorTests",
            dependencies: [
                "IndexStoreInfra","LoggingAuditor"]
        ),

        .target(
            name: "TestQualityAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                // exact-double-equality and fp-equality are one rule. The
                // detector lives in FloatingPointSafetyAuditor; this checker
                // reports it at error severity inside assertions.
                "FloatingPointSafetyAuditor",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["TestQualityAuditor.docc"]
        ),
        .testTarget(
            name: "TestQualityAuditorTests",
            dependencies: ["TestQualityAuditor", "FloatingPointSafetyAuditor"]
        ),

        .target(
            name: "ContextAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["ContextAuditor.docc"]
        ),
        .testTarget(
            name: "ContextAuditorTests",
            dependencies: [
                "IndexStoreInfra","ContextAuditor"]
        ),

        .target(
            name: "DependencyAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["DependencyAuditor.docc"]
        ),
        .testTarget(
            name: "DependencyAuditorTests",
            dependencies: [
                "IndexStoreInfra","DependencyAuditor"]
        ),

        .target(
            name: "SubmoduleAuditor",
            dependencies: [
                "IndexStoreInfra","QualityGateCore"]
        ),
        .testTarget(
            name: "SubmoduleAuditorTests",
            dependencies: [
                "IndexStoreInfra","SubmoduleAuditor"]
        ),

        .target(
            name: "ReleaseReadinessAuditor",
            dependencies: ["QualityGateCore"],
            exclude: ["ReleaseReadinessAuditor.docc"]
        ),
        .testTarget(
            name: "ReleaseReadinessAuditorTests",
            dependencies: ["ReleaseReadinessAuditor"]
        ),

        .target(
            name: "FloatingPointSafetyAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["FloatingPointSafetyAuditor.docc"]
        ),
        .testTarget(
            name: "FloatingPointSafetyAuditorTests",
            dependencies: [
                "IndexStoreInfra","FloatingPointSafetyAuditor"]
        ),

        .target(
            name: "MCPReadinessAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["MCPReadinessAuditor.docc"]
        ),
        .testTarget(
            name: "MCPReadinessAuditorTests",
            dependencies: [
                "IndexStoreInfra","MCPReadinessAuditor"]
        ),

        .target(
            name: "StochasticDeterminismAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["StochasticDeterminismAuditor.docc"]
        ),
        .testTarget(
            name: "StochasticDeterminismAuditorTests",
            dependencies: [
                "IndexStoreInfra","StochasticDeterminismAuditor"]
        ),

        .target(
            name: "TemporalDeterminismAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["TemporalDeterminismAuditor.docc"]
        ),
        .testTarget(
            name: "TemporalDeterminismAuditorTests",
            dependencies: ["TemporalDeterminismAuditor"]
        ),

        .target(
            name: "GPUSafetyAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["GPUSafetyAuditor.docc"]
        ),
        .testTarget(
            name: "GPUSafetyAuditorTests",
            dependencies: ["GPUSafetyAuditor"]
        ),

        .target(
            name: "LivenessAuditor",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ,
            exclude: ["LivenessAuditor.docc"]
        ),
        .testTarget(
            name: "LivenessAuditorTests",
            dependencies: ["LivenessAuditor"]
        ),

        .target(
            name: "BoundedIOAuditor",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ,
            exclude: ["BoundedIOAuditor.docc"]
        ),
        .testTarget(
            name: "BoundedIOAuditorTests",
            dependencies: ["BoundedIOAuditor"]
        ),

        .target(
            name: "MemoryLifecycleGuard",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["MemoryLifecycleGuard.docc"]
        ),
        .testTarget(
            name: "MemoryLifecycleGuardTests",
            dependencies: ["MemoryLifecycleGuard"]
        ),
        .target(
            name: "ProcessSafetyAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "ProcessSafetyAuditorTests",
            dependencies: ["ProcessSafetyAuditor"]
        ),

        .target(
            name: "ComplexityAnalyzer",
            dependencies: [
                "QualityGateCore",
                "IJSSensor",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            exclude: ["ComplexityAnalyzer.docc"]
        ),
        .testTarget(
            name: "ComplexityAnalyzerTests",
            dependencies: ["ComplexityAnalyzer", "IJSSensor"]
        ),
        .target(
            name: "LegibilityAnalyzer",
            dependencies: [
                "QualityGateCore",
                "IJSSensor",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            exclude: ["LegibilityAnalyzer.docc"]
        ),
        .testTarget(
            name: "LegibilityAnalyzerTests",
            dependencies: ["LegibilityAnalyzer", "IJSSensor"]
        ),

        .target(
            name: "HIGAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "HIGAuditorTests",
            dependencies: ["HIGAuditor"]
        ),

        .target(
            name: "XcodeBuildChecker",
            dependencies: ["QualityGateCore", "BuildChecker", "IndexStoreInfra"]
        ),

        // MARK: - IndexStoreInfra
        .target(
            name: "IndexStoreInfra",
            dependencies: [
                "QualityGateCore",
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            exclude: ["IndexStoreInfra.docc"]
        ),
        .testTarget(
            name: "IndexStoreInfraTests",
            dependencies: ["IndexStoreInfra", "QualityGateCore"]
        ),

        // MARK: - AppIntentsAuditor
        .target(
            name: "AppIntentsAuditor",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["AppIntentsAuditor.docc"]
        ),
        .testTarget(
            name: "AppIntentsAuditorTests",
            dependencies: [
                "IndexStoreInfra","AppIntentsAuditor"]
        ),

        // MARK: - IJS Modules
        .target(
            name: "IJSSensor",
            dependencies: [
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
            ]
        ),

        .target(
            name: "IJSAggregator",
            dependencies: [
                "IJSSensor",
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "IJSAggregatorTests",
            dependencies: ["IJSAggregator"]
        ),

        .target(
            name: "IJSRefiner",
            dependencies: [
                "IJSSensor",
                "IJSAggregator",
                .product(name: "BusinessMath", package: "BusinessMath"),
            ]
        ),
        .testTarget(
            name: "IJSRefinerTests",
            dependencies: ["IJSRefiner"]
        ),

        .target(
            name: "IJSPolicyDiscovery",
            dependencies: [
                "IJSSensor",
                "IJSAggregator",
                "IJSRefiner",
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
            ]
        ),
        .testTarget(
            name: "IJSPolicyDiscoveryTests",
            dependencies: ["IJSPolicyDiscovery"]
        ),

        .target(
            name: "ConsistencyChecker",
            dependencies: [
                "QualityGateCore",
                "IJSSensor",
                "IJSAggregator",
                "IJSPolicyDiscovery",
            ]
        ),
        .testTarget(
            name: "ConsistencyCheckerTests",
            dependencies: [
                "ConsistencyChecker",
                "IJSSensor",
                "IJSAggregator",
                "IJSPolicyDiscovery",
            ]
        ),

        // MARK: - Dashboard
        .target(
            name: "IJSDashboardCore",
            dependencies: [
                "IJSSensor",
                "IJSAggregator",
                "JudgmentWorkbench",
            ]
        ),
        .testTarget(
            name: "IJSDashboardCoreTests",
            dependencies: [
                "IJSDashboardCore",
                "IJSAggregator",
                "IJSSensor",
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
            ]
        ),
        .target(
            name: "IJSDashboardCLI",
            dependencies: [
                "IJSDashboardCore",
                "IJSSensor",
                "IJSAggregator",
                "JudgmentWorkbench",
                "CorpusService",
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
                .product(name: "SwiftCLIKit", package: "SwiftCLIKit"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "IJSDashboardCLITests",
            dependencies: [
                "IJSDashboardCLI",
                "IJSDashboardCore",
                "IJSSensor",
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
                .product(name: "SwiftCLIKit", package: "SwiftCLIKit"),
            ]
        ),
        .target(
            name: "IJSDashboardUI",
            dependencies: [
                "IJSDashboardCore",
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                .product(name: "SwiftGUIKit", package: "SwiftCLIKit"),
                .product(name: "SwiftGUIKitSwiftUI", package: "SwiftCLIKit"),
                .product(name: "SwiftCLIKit", package: "SwiftCLIKit"),
                .product(name: "BusinessMath", package: "BusinessMath"),
                .product(name: "BusinessMathUI", package: "BusinessMath-UI"),
                .product(name: "BusinessMathAdapters", package: "BusinessMath-Adapters"),
            ]
        ),
        .executableTarget(
            name: "ijs-dashboard-preview",
            dependencies: [
                "IJSDashboardUI",
                "IJSDashboardCore",
                .product(name: "SwiftGUIKit", package: "SwiftCLIKit"),
                .product(name: "SwiftCLIKit", package: "SwiftCLIKit"),
            ]
        ),
        .executableTarget(
            name: "IJSDashboardApp",
            dependencies: [
                "IJSDashboardCore",
                "IJSDashboardUI",
            ]
        ),
        .testTarget(
            name: "IJSDashboardUITests",
            dependencies: [
                "IJSDashboardUI",
                "IJSDashboardCore",
                .product(name: "SwiftGUIKit", package: "SwiftCLIKit"),
                .product(name: "SwiftCLIKit", package: "SwiftCLIKit"),
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
            ]
        ),

        // MARK: - Test Kit
        .target(
            name: "QualityGateTestKit",
            dependencies: ["QualityGateCore"]
        ),
        .testTarget(
            name: "QualityGateTestKitTests",
            dependencies: [
                "QualityGateTestKit",
                "SafetyAuditor",
            ]
        ),

        // MARK: - Plugin overlay (Phase 4b)
        .target(
            name: "GatePlugins",
            dependencies: ["QualityGateCore"]
        ),
        .testTarget(
            name: "GatePluginsTests",
            dependencies: ["GatePlugins"]
        ),

        // MARK: - Major-points parity (Phase 4c)
        .target(
            name: "IdiomAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "IdiomAuditorTests",
            dependencies: ["IdiomAuditor"]
        ),
        .target(
            name: "DuplicationAuditor",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "DuplicationAuditorTests",
            dependencies: [
                "IndexStoreInfra","DuplicationAuditor"]
        ),
        .target(
            name: "SmellPack",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "SmellPackTests",
            dependencies: ["SmellPack"]
        ),
        .target(
            name: "KeychainSecretsChecker",
            dependencies: [
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "KeychainSecretsCheckerTests",
            dependencies: [
                "IndexStoreInfra","KeychainSecretsChecker"]
        ),
        .target(
            name: "PrivacyManifestChecker",
            dependencies: [
                "IndexStoreInfra","QualityGateCore"]
        ),
        .testTarget(
            name: "PrivacyManifestCheckerTests",
            dependencies: [
                "IndexStoreInfra","PrivacyManifestChecker"]
        ),
        .target(
            name: "ControlMapping",
            dependencies: [
                "QualityGateCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ControlMappingTests",
            dependencies: ["ControlMapping"]
        ),

        // MARK: - Judgment workbench (Phase 3a §7)
        .target(
            name: "JudgmentWorkbench",
            dependencies: [
                "QualityGateCore",
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
            ]
        ),
        .testTarget(
            name: "JudgmentWorkbenchTests",
            dependencies: ["JudgmentWorkbench", "IdiomAuditor", "SmellPack", "GatePlugins"]
        ),

        // MARK: - Trust service core (Phase 3b)
        .target(
            name: "CorpusService",
            dependencies: [
                "QualityGateCore",
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "CorpusServiceTests",
            dependencies: ["CorpusService"]
        ),

        // MARK: - CI parity (Phase 2)
        .target(
            name: "GateCI",
            dependencies: [
                "QualityGateCore",
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
            ]
        ),
        .testTarget(
            name: "GateCITests",
            dependencies: ["GateCI"]
        ),

        // MARK: - Narrative providers (Claude primary, on-device Foundation Models fallback)
        .target(
            name: "NarrativeCore",
            dependencies: [
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
            ]
        ),
        .testTarget(
            name: "NarrativeCoreTests",
            dependencies: ["NarrativeCore"]
        ),

        // MARK: - CLI
        .executableTarget(
            name: "QualityGateCLI",
            dependencies: [
                "BoundedIOAuditor",
                "LivenessAuditor",
                "QualityGateCore",
                "NarrativeCore",
                "GateCI",
                "GatePlugins",
                "CorpusService",
                "IdiomAuditor",
                "SmellPack",
                "DuplicationAuditor",
                "KeychainSecretsChecker",
                "PrivacyManifestChecker",
                "ControlMapping",
                "SafetyAuditor",
                "BuildChecker",
                "TestRunner",
                "DocLinter",
                "DocCodeAuditor",
                "DocGeneratedAuditor",
                "DocCoverageChecker",
                "DiskCleaner",
                "UnreachableCodeAuditor",
                "RecursionAuditor",
                "ConcurrencyAuditor",
                "PointerEscapeAuditor",
                "MemoryBuilder",
                "AccessibilityAuditor",
                "StatusAuditor",
                "SwiftVersionChecker",
                "LoggingAuditor",
                "TestQualityAuditor",
                "ContextAuditor",
                "DependencyAuditor",
                "SubmoduleAuditor",
                "ReleaseReadinessAuditor",
                "FloatingPointSafetyAuditor",
                "StochasticDeterminismAuditor",
                "TemporalDeterminismAuditor",
                "GPUSafetyAuditor",
                "MemoryLifecycleGuard",
                "MCPReadinessAuditor",
                "ProcessSafetyAuditor",
                "ComplexityAnalyzer",
                "LegibilityAnalyzer",
                "HIGAuditor",
                "XcodeBuildChecker",
                "AppIntentsAuditor",
                "ConsistencyChecker",
                "IJSSensor",
                "IJSAggregator",
                "IJSRefiner",
                "IJSDashboardCore",
                "IJSDashboardCLI",
                "IJSDashboardUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["README.md", "QualityGateCLI.docc"]
        ),
        // Phase 1 acceptance: exercises the built `quality-gate` binary
        // against fixture upstream repos (foreign mode's read-only promise).
        .testTarget(
            name: "ForeignModeAcceptanceTests",
            dependencies: ["QualityGateCLI", "QualityGateCore"]
        ),
        // Phase 2 acceptance: local run and `ci` run of the same fixture
        // must produce byte-identical diagnostics (the parity guarantee).
        .testTarget(
            name: "CIParityTests",
            dependencies: ["QualityGateCLI", "QualityGateCore"]
        ),

        // MARK: - IJS MCP Server
        .executableTarget(
            name: "IJSMCPServer",
            dependencies: [
                "IJSSensor",
                "IJSAggregator",
                "IJSRefiner",
                "IJSPolicyDiscovery",
                "IJSDashboardCore",
                .product(name: "SwiftMCPServer", package: "SwiftMCPServer"),
            ]
        ),

        // MARK: - Plugins
        .plugin(
            name: "QualityGatePlugin",
            capability: .command(
                intent: .custom(
                    verb: "quality-gate",
                    description: "Run quality gate checks on the package"
                ),
                permissions: []
            )
        ),
    ]
)
