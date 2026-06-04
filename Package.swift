// swift-tools-version: 6.2
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
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/apple/indexstore-db.git", branch: "main"),
        .package(url: "https://github.com/jpurnell/quality-gate-types.git", from: "1.0.0"),
		.package(url: "https://github.com/jpurnell/BusinessMath", from: "2.1.6"),
        .package(url: "https://github.com/jpurnell/SwiftCLIKit.git", from: "1.0.1"),
        .package(path: "../SwiftMCPServer"),
    ],
    targets: [
        // MARK: - Core Module
        .target(
            name: "QualityGateCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
            ]
        ),
        .testTarget(
            name: "QualityGateCoreTests",
            dependencies: ["QualityGateCore"]
        ),

        // MARK: - Checker Modules
        .target(
            name: "SafetyAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "SafetyAuditorTests",
            dependencies: ["SafetyAuditor"]
        ),

        .target(
            name: "BuildChecker",
            dependencies: ["QualityGateCore"]
        ),
        .testTarget(
            name: "BuildCheckerTests",
            dependencies: ["BuildChecker"]
        ),

        .target(
            name: "TestRunner",
            dependencies: ["QualityGateCore"]
        ),
        .testTarget(
            name: "TestRunnerTests",
            dependencies: ["TestRunner"]
        ),

        .target(
            name: "DocLinter",
            dependencies: ["QualityGateCore"]
        ),
        .testTarget(
            name: "DocLinterTests",
            dependencies: ["DocLinter"]
        ),

        .target(
            name: "DocCoverageChecker",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "DocCoverageCheckerTests",
            dependencies: ["DocCoverageChecker"]
        ),

        .target(
            name: "DiskCleaner",
            dependencies: ["QualityGateCore"]
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
            ]
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
            ]
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
            ]
        ),
        .testTarget(
            name: "ConcurrencyAuditorTests",
            dependencies: ["ConcurrencyAuditor"]
        ),

        .target(
            name: "PointerEscapeAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "PointerEscapeAuditorTests",
            dependencies: ["PointerEscapeAuditor"]
        ),

        .target(
            name: "MemoryBuilder",
            dependencies: [
                "QualityGateCore",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "MemoryBuilderTests",
            dependencies: ["MemoryBuilder"]
        ),

        .target(
            name: "AccessibilityAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["ACCESSIBILITY_MATRIX.md"]
        ),
        .testTarget(
            name: "AccessibilityAuditorTests",
            dependencies: ["AccessibilityAuditor"]
        ),

        .target(
            name: "StatusAuditor",
            dependencies: ["QualityGateCore"]
        ),
        .testTarget(
            name: "StatusAuditorTests",
            dependencies: ["StatusAuditor"]
        ),

        .target(
            name: "SwiftVersionChecker",
            dependencies: ["QualityGateCore"]
        ),
        .testTarget(
            name: "SwiftVersionCheckerTests",
            dependencies: ["SwiftVersionChecker"]
        ),

        .target(
            name: "LoggingAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "LoggingAuditorTests",
            dependencies: ["LoggingAuditor"]
        ),

        .target(
            name: "TestQualityAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "TestQualityAuditorTests",
            dependencies: ["TestQualityAuditor"]
        ),

        .target(
            name: "ContextAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "ContextAuditorTests",
            dependencies: ["ContextAuditor"]
        ),

        .target(
            name: "DependencyAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "DependencyAuditorTests",
            dependencies: ["DependencyAuditor"]
        ),

        .target(
            name: "ReleaseReadinessAuditor",
            dependencies: ["QualityGateCore"]
        ),
        .testTarget(
            name: "ReleaseReadinessAuditorTests",
            dependencies: ["ReleaseReadinessAuditor"]
        ),

        .target(
            name: "FloatingPointSafetyAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "FloatingPointSafetyAuditorTests",
            dependencies: ["FloatingPointSafetyAuditor"]
        ),

        .target(
            name: "MCPReadinessAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "MCPReadinessAuditorTests",
            dependencies: ["MCPReadinessAuditor"]
        ),

        .target(
            name: "StochasticDeterminismAuditor",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "StochasticDeterminismAuditorTests",
            dependencies: ["StochasticDeterminismAuditor"]
        ),

        .target(
            name: "MemoryLifecycleGuard",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "MemoryLifecycleGuardTests",
            dependencies: ["MemoryLifecycleGuard"]
        ),
        .target(
            name: "ProcessSafetyAuditor",
            dependencies: [
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
            ]
        ),
        .testTarget(
            name: "ComplexityAnalyzerTests",
            dependencies: ["ComplexityAnalyzer", "IJSSensor"]
        ),

        .target(
            name: "HIGAuditor",
            dependencies: [
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
            dependencies: ["QualityGateCore", "BuildChecker"]
        ),

        // MARK: - IndexStoreInfra
        .target(
            name: "IndexStoreInfra",
            dependencies: [
                "QualityGateCore",
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ]
        ),
        .testTarget(
            name: "IndexStoreInfraTests",
            dependencies: ["IndexStoreInfra"]
        ),

        // MARK: - AppIntentsAuditor
        .target(
            name: "AppIntentsAuditor",
            dependencies: [
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "AppIntentsAuditorTests",
            dependencies: ["AppIntentsAuditor"]
        ),

        // MARK: - IJS Modules
        .target(
            name: "IJSSensor",
            dependencies: [
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
            ]
        ),
        .testTarget(
            name: "IJSSensorTests",
            dependencies: ["IJSSensor"]
        ),

        .target(
            name: "IJSAggregator",
            dependencies: [
                "IJSSensor",
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
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
                .product(name: "SwiftCLIKit", package: "SwiftCLIKit"),
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

        // MARK: - CLI
        .executableTarget(
            name: "QualityGateCLI",
            dependencies: [
                "QualityGateCore",
                "SafetyAuditor",
                "BuildChecker",
                "TestRunner",
                "DocLinter",
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
                "ReleaseReadinessAuditor",
                "FloatingPointSafetyAuditor",
                "StochasticDeterminismAuditor",
                "MemoryLifecycleGuard",
                "MCPReadinessAuditor",
                "ProcessSafetyAuditor",
                "ComplexityAnalyzer",
                "HIGAuditor",
                "XcodeBuildChecker",
                "AppIntentsAuditor",
                "ConsistencyChecker",
                "IJSSensor",
                "IJSAggregator",
                "IJSRefiner",
                "IJSDashboardCore",
                "IJSDashboardCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["README.md"]
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
