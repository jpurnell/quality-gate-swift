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
            name: "ServerSurface",
            targets: ["ServerSurface"]
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
            name: "IJSRefiner",
            targets: ["IJSRefiner"]
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
        // JudgmentWorkbench moved to quality-gate-corpus-kit 1.18.0 and is consumed from
        // there. It declared QualityGateCore and used nothing from it, which is what had
        // kept it here and, through it, made quality-gate-dashboard link this whole package.
        // Trust service core (Phase 3b)
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
        // CLI executable
        .executable(
            name: "quality-gate",
            targets: ["QualityGateCLI"]
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
        .package(url: "https://github.com/jpurnell/quality-gate-types.git", from: "1.7.0"),
        .package(url: "https://github.com/jpurnell/swift-vigil.git", from: "0.9.0"),
        .package(url: "https://github.com/jpurnell/SwiftDeterminism.git", from: "1.3.0"),
        .package(url: "https://github.com/jpurnell/swift-process-kernel.git", from: "1.0.0"),
        // HTTPS, not git@ — CI authenticates private dependencies by rewriting
        // `https://github.com/` through a token (`url.insteadOf`), which cannot
        // touch an SSH remote. With the SSH form this dependency failed on any
        // machine without a GitHub SSH key regardless of how the token was
        // scoped: "Host key verification failed", observed on the runner host.
        .package(url: "https://github.com/jpurnell/quality-gate-corpus-kit.git", from: "1.22.1"),
		// 3.0.0-alpha.8 carries the Linux fallback-logger fix. The 2.x line is divergent from
		// BusinessMath's main and has the same defect, so no 2.x version can reach it; the
		// major bump was measured rather than assumed — IJSRefiner builds and all 3411 tests
		// pass against it, so the API break this line guards against does not touch us.
		.package(url: "https://github.com/jpurnell/BusinessMath", from: "3.0.0-alpha.9"),
        // 1.4.0, not 1.3.1. The v1.3.1 tag was moved three times, and SwiftPM keeps a
        // machine-global trust-on-first-use fingerprint per version, so every consumer that had
        // ever resolved 1.3.1 was refused on every machine — this package could not resolve from
        // a clean checkout at all, with warm caches the only thing hiding it. SwiftCLIKit
        // published 1.4.0 rather than move the tag a fourth time; a published version tag is
        // immutable, and correcting a release means publishing the next one.
        .package(url: "https://github.com/jpurnell/swift-cli-kit.git", from: "1.4.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // MARK: - Core Module
        .target(
            name: "QualityGateCore",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
                .product(name: "ProcessKernel", package: "swift-process-kernel"),
                .product(name: "VigilKit", package: "swift-vigil"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.copy("QualityGateCore.docc")]
        ),
        .testTarget(
            name: "QualityGateCoreTests",
            dependencies: ["QualityGateCore"]
        ),

        // MARK: - External-input source model (SwiftSyntax adapter)
        .target(
            name: "ExternalInputSyntax",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            resources: [.copy("ExternalInputSyntax.docc")]
        ),
        .testTarget(
            name: "ExternalInputSyntaxTests",
            dependencies: [
                "ExternalInputSyntax",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),

        // MARK: - Checker Modules
        .target(
            name: "SafetyAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                "ExternalInputSyntax",
                "ServerSurface",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("SafetyAuditor.docc")]
        ),
        .testTarget(
            name: "SafetyAuditorTests",
            dependencies: [
                "IndexStoreInfra","SafetyAuditor"]
        ),

        // What a package exposes to a network — listeners and handlers — as data for rules.
        // Shared infrastructure (TheGateIsNotYetAggressive.md §2.2 item 1): SafetyAuditor's
        // listener rules read it now; the server-surface proposals add columns to it later.
        .target(
            name: "ServerSurface",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("ServerSurface.docc")]
        ),
        .testTarget(
            name: "ServerSurfaceTests",
            dependencies: ["ServerSurface", "QualityGateCore"]
        ),

        .target(
            name: "BuildChecker",
            dependencies: ["QualityGateCore", .product(name: "QualityGateLogging", package: "quality-gate-types")],
            resources: [.copy("BuildChecker.docc")]
        ),
        .testTarget(
            name: "BuildCheckerTests",
            dependencies: ["BuildChecker", "QualityGateCore"]
        ),

        .testTarget(
            name: "XcodeBuildCheckerTests",
            dependencies: ["XcodeBuildChecker", "QualityGateCore"]
        ),

        .target(
            name: "TestRunner",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("TestRunner.docc")]
        ),
        .testTarget(
            name: "TestRunnerTests",
            dependencies: ["TestRunner", "IndexStoreInfra"]
        ),

        .target(
            name: "DocLinter",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            // Declared, not excluded. swift-docc-plugin locates a catalogue through the
            // target's `sourceFiles`, which `exclude:` removes it from — so excluding silences
            // SwiftPM's unhandled-file warning by handing DocC nothing, and doc-lint goes green
            // over an article it never opened. This is the checker that reports that failure
            // mode in other packages; it should not be the one demonstrating it.
            resources: [.copy("DocLinter.docc")]
        ),
        .testTarget(
            name: "DocLinterTests",
            dependencies: [
                "IndexStoreInfra","DocLinter"]
        ),

        .target(
            name: "DocCodeAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("DocCodeAuditor.docc")]
        ),
        .testTarget(
            name: "DocCodeAuditorTests",
            dependencies: ["DocCodeAuditor"]
        ),

        .target(
            name: "DocGeneratedAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("DocGeneratedAuditor.docc")]
        ),
        .testTarget(
            name: "DocGeneratedAuditorTests",
            dependencies: ["DocGeneratedAuditor"]
        ),

        .target(
            name: "DocCoverageChecker",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("DocCoverageChecker.docc")]
        ),
        .testTarget(
            name: "DocCoverageCheckerTests",
            dependencies: ["DocCoverageChecker"]
        ),

        .target(
            name: "DiskCleaner",
            dependencies: ["QualityGateCore", .product(name: "QualityGateLogging", package: "quality-gate-types")],
            resources: [.copy("DiskCleaner.docc")]
        ),
        .testTarget(
            name: "DiskCleanerTests",
            dependencies: ["DiskCleaner"]
        ),

        .target(
            name: "UnreachableCodeAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            resources: [.copy("UnreachableCodeAuditor.docc")]
        ),
        .testTarget(
            name: "UnreachableCodeAuditorTests",
            dependencies: ["UnreachableCodeAuditor"],
            exclude: ["Fixtures"]
        ),

        // Lexical binding resolution over SwiftSyntax: what a name is bound to at a
        // point in a walk. SwiftSyntax only — no QualityGateCore — so any auditor that
        // must tell a local from a member can depend on it.
        .target(
            name: "SyntaxScope",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            resources: [.copy("SyntaxScope.docc")]
        ),
        .testTarget(
            name: "SyntaxScopeTests",
            dependencies: [
                "SyntaxScope",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),

        .target(
            name: "RecursionAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                "IndexStoreInfra",
                "SyntaxScope",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("RecursionAuditor.docc")]
        ),
        .testTarget(
            name: "RecursionAuditorTests",
            dependencies: ["RecursionAuditor"]
        ),

        .target(
            name: "ConcurrencyAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                "IndexStoreInfra",
                "SyntaxScope",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("ConcurrencyAuditor.docc")]
        ),
        .testTarget(
            name: "ConcurrencyAuditorTests",
            dependencies: ["ConcurrencyAuditor"]
        ),

        .target(
            name: "PointerEscapeAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("PointerEscapeAuditor.docc")]
        ),
        .testTarget(
            name: "PointerEscapeAuditorTests",
            dependencies: [
                "IndexStoreInfra","PointerEscapeAuditor"]
        ),

        .target(
            name: "MemoryBuilder",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.copy("MemoryBuilder.docc")]
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
        .testTarget(
            name: "AccessibilityCLITests",
            dependencies: ["AccessibilityCLI", "AccessibilityCore", "QualityGateCore"]
        ),
        .target(
            name: "AccessibilityAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "AccessibilityCore",
                "AccessibilitySwiftUI",
                "AccessibilityCLI",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["ACCESSIBILITY_MATRIX.md"],
            resources: [.copy("AccessibilityAuditor.docc")]
        ),
        .testTarget(
            name: "AccessibilityAuditorTests",
            dependencies: [
                "IndexStoreInfra","AccessibilityAuditor", "QualityGateCore"]
        ),

        .target(
            name: "StatusAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                .product(name: "SwiftDeterminism", package: "SwiftDeterminism"),
            ],
            resources: [.copy("StatusAuditor.docc")]
        ),
        .testTarget(
            name: "StatusAuditorTests",
            dependencies: ["StatusAuditor"]
        ),

        .target(
            name: "SwiftVersionChecker",
            dependencies: ["QualityGateCore", .product(name: "QualityGateLogging", package: "quality-gate-types")],
            resources: [.copy("SwiftVersionChecker.docc")]
        ),
        .testTarget(
            name: "SwiftVersionCheckerTests",
            dependencies: ["SwiftVersionChecker"]
        ),

        .target(
            name: "LoggingAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("LoggingAuditor.docc")]
        ),
        .testTarget(
            name: "LoggingAuditorTests",
            dependencies: [
                "IndexStoreInfra","LoggingAuditor"]
        ),

        .target(
            name: "TestQualityAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                // exact-double-equality and fp-equality are one rule. The
                // detector lives in FloatingPointSafetyAuditor; this checker
                // reports it at error severity inside assertions.
                "FloatingPointSafetyAuditor",
                .product(name: "SwiftDeterminism", package: "SwiftDeterminism"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("TestQualityAuditor.docc")]
        ),
        .testTarget(
            name: "TestQualityAuditorTests",
            dependencies: ["TestQualityAuditor", "FloatingPointSafetyAuditor"]
        ),

        .target(
            name: "ContextAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("ContextAuditor.docc")]
        ),
        .testTarget(
            name: "ContextAuditorTests",
            dependencies: [
                "IndexStoreInfra","ContextAuditor"]
        ),

        .target(
            name: "DependencyAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("DependencyAuditor.docc")]
        ),
        .testTarget(
            name: "DependencyAuditorTests",
            dependencies: [
                "IndexStoreInfra","DependencyAuditor"]
        ),

        .target(
            name: "SubmoduleAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra","QualityGateCore"]
        ),
        .testTarget(
            name: "SubmoduleAuditorTests",
            dependencies: [
                "IndexStoreInfra","SubmoduleAuditor"]
        ),

        .target(
            name: "ReleaseReadinessAuditor",
            dependencies: ["QualityGateCore", .product(name: "QualityGateLogging", package: "quality-gate-types")],
            resources: [.copy("ReleaseReadinessAuditor.docc")]
        ),
        .testTarget(
            name: "ReleaseReadinessAuditorTests",
            dependencies: ["ReleaseReadinessAuditor"]
        ),

        .target(
            name: "FloatingPointSafetyAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("FloatingPointSafetyAuditor.docc")]
        ),
        .testTarget(
            name: "FloatingPointSafetyAuditorTests",
            dependencies: [
                "IndexStoreInfra","FloatingPointSafetyAuditor"]
        ),

        .target(
            name: "MCPReadinessAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("MCPReadinessAuditor.docc")]
        ),
        .testTarget(
            name: "MCPReadinessAuditorTests",
            dependencies: [
                "IndexStoreInfra","MCPReadinessAuditor"]
        ),

        .target(
            name: "StochasticDeterminismAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "IndexStoreInfra",
                "QualityGateCore",
                // `SecurityValueSite`: where the security rules own a line, this checker stands
                // down, and it must read "the value" exactly as they do (ASeedIsNotASecret.md §3.6).
                "SafetyAuditor",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("StochasticDeterminismAuditor.docc")]
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
            resources: [.copy("TemporalDeterminismAuditor.docc")]
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
            resources: [.copy("GPUSafetyAuditor.docc")]
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
            resources: [.copy("LivenessAuditor.docc")]
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
            resources: [.copy("BoundedIOAuditor.docc")]
        ),
        .testTarget(
            name: "BoundedIOAuditorTests",
            dependencies: ["BoundedIOAuditor"]
        ),

        .target(
            name: "MemoryLifecycleGuard",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("MemoryLifecycleGuard.docc")]
        ),
        .testTarget(
            name: "MemoryLifecycleGuardTests",
            // ConcurrencyAuditor: the round-trip test runs both checkers on one source.
            dependencies: ["MemoryLifecycleGuard", "ConcurrencyAuditor"]
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
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                // CorpusKit directly: a checker depends on the corpus's
                // shared types, never on the IJS modules that write the corpus.
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            resources: [.copy("ComplexityAnalyzer.docc")]
        ),
        .testTarget(
            name: "ComplexityAnalyzerTests",
            dependencies: ["ComplexityAnalyzer", .product(name: "CorpusKit", package: "quality-gate-corpus-kit")]
        ),
        .target(
            name: "LegibilityAnalyzer",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                // CorpusKit directly — see ComplexityAnalyzer above.
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            resources: [.copy("LegibilityAnalyzer.docc")]
        ),
        .testTarget(
            name: "LegibilityAnalyzerTests",
            dependencies: ["LegibilityAnalyzer", .product(name: "CorpusKit", package: "quality-gate-corpus-kit")]
        ),

        .target(
            name: "HIGAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
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
            dependencies: ["QualityGateCore", "BuildChecker", "IndexStoreInfra", .product(name: "QualityGateLogging", package: "quality-gate-types")]
        ),

        // MARK: - IndexStoreInfra
        .target(
            name: "IndexStoreInfra",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            resources: [.copy("IndexStoreInfra.docc")]
        ),
        .testTarget(
            name: "IndexStoreInfraTests",
            dependencies: ["IndexStoreInfra", "QualityGateCore"]
        ),

        // MARK: - AppIntentsAuditor
        .target(
            name: "AppIntentsAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                "IndexStoreInfra",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            resources: [.copy("AppIntentsAuditor.docc")]
        ),
        .testTarget(
            name: "AppIntentsAuditorTests",
            dependencies: [
                "IndexStoreInfra","AppIntentsAuditor"]
        ),

        // MARK: - IJS Modules


        .target(
            name: "IJSRefiner",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                .product(name: "SwiftDeterminism", package: "SwiftDeterminism"),
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                .product(name: "IJSAggregator", package: "quality-gate-corpus-kit"),
                .product(name: "BusinessMath", package: "BusinessMath"),
            ]
        ),
        .testTarget(
            name: "IJSRefinerTests",
            dependencies: ["IJSRefiner"]
        ),


        .target(
            name: "ConsistencyChecker",
            dependencies: [
                "QualityGateCore",
                .product(name: "SwiftDeterminism", package: "SwiftDeterminism"),
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                .product(name: "IJSAggregator", package: "quality-gate-corpus-kit"),
                .product(name: "IJSPolicyDiscovery", package: "quality-gate-corpus-kit"),
            ]
        ),
        .testTarget(
            name: "ConsistencyCheckerTests",
            dependencies: [
                "ConsistencyChecker",
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                .product(name: "IJSAggregator", package: "quality-gate-corpus-kit"),
                .product(name: "IJSPolicyDiscovery", package: "quality-gate-corpus-kit"),
            ]
        ),

        // MARK: - Dashboard
        .target(
            name: "IJSDashboardCLI",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                .product(name: "IJSDashboardCore", package: "quality-gate-corpus-kit"),
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                .product(name: "IJSAggregator", package: "quality-gate-corpus-kit"),
                .product(name: "JudgmentWorkbench", package: "quality-gate-corpus-kit"),
                "CorpusService",
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
                .product(name: "SwiftCLIKit", package: "swift-cli-kit"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "IJSDashboardCLITests",
            dependencies: [
                "IJSDashboardCLI",
                .product(name: "IJSDashboardCore", package: "quality-gate-corpus-kit"),
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                .product(name: "QualityGateTypes", package: "quality-gate-types"),
                .product(name: "SwiftCLIKit", package: "swift-cli-kit"),
            ]
        ),
        // IJSDashboardUI, ijs-dashboard-preview, IJSDashboardApp and
        // IJSDashboardUITests moved to the quality-gate-dashboard package.

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
            dependencies: ["QualityGateCore", .product(name: "QualityGateLogging", package: "quality-gate-types")]
        ),
        .testTarget(
            name: "GatePluginsTests",
            dependencies: ["GatePlugins"]
        ),

        // MARK: - Major-points parity (Phase 4c)
        .target(
            name: "IdiomAuditor",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
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
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
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
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
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
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                "QualityGateCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ControlMappingTests",
            dependencies: ["ControlMapping", "SafetyAuditor"]
        ),

        // MARK: - Judgment workbench (Phase 3a §7)
        // The sources live in quality-gate-corpus-kit 1.18.0. What stays is the half of the
        // suite that can only be proven here: the golden re-audit tests drive IdiomAuditor,
        // SmellPack and CustomRulesChecker end to end to show that the marker MarkerWriter
        // writes is the one those auditors actually honour on the next run. Moving them with
        // the sources would have meant asserting the convention against a copy of itself.
        .testTarget(
            name: "JudgmentWorkbenchTests",
            dependencies: [
                .product(name: "JudgmentWorkbench", package: "quality-gate-corpus-kit"),
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                "QualityGateCore",
                "IdiomAuditor",
                "SmellPack",
                "GatePlugins",
            ]
        ),

        // MARK: - Trust service core (Phase 3b)
        .target(
            name: "CorpusService",
            dependencies: [
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
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
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
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
                .product(name: "QualityGateLogging", package: "quality-gate-types"),
                .product(name: "SwiftDeterminism", package: "SwiftDeterminism"),
                "IndexStoreInfra",
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
                .product(name: "CorpusKit", package: "quality-gate-corpus-kit"),
                .product(name: "IJSAggregator", package: "quality-gate-corpus-kit"),
                "IJSRefiner",
                .product(name: "IJSDashboardCore", package: "quality-gate-corpus-kit"),
                "IJSDashboardCLI",
                // IJSDashboardUI is deliberately absent. It moved to the
                // quality-gate-dashboard package on 2026-09-05 — linking it here
                // pulled SwiftUI, AVKit and three private BusinessMath packages
                // into the CLI, so the gate could not build without Xcode.
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            exclude: ["README.md"],
            resources: [.copy("QualityGateCLI.docc")]
        ),
        // Phase 1 acceptance: exercises the built `quality-gate` binary
        // against fixture upstream repos (foreign mode's read-only promise).
        .testTarget(
            name: "ForeignModeAcceptanceTests",
            dependencies: ["QualityGateCLI", "QualityGateCore", "QualityGateTestKit"]
        ),
        // Phase 2 acceptance: local run and `ci` run of the same fixture
        // must produce byte-identical diagnostics (the parity guarantee).
        .testTarget(
            name: "CIParityTests",
            // `GateCI` for `CIIdentityProbe`: the tripwire fixtures have to predict the
            // identity the gate run will record, and under GitHub Actions that is the
            // provider-verified actor rather than `USER`. Reimplementing that rule in the
            // test is what made the fixture pass only on a machine whose username matched
            // the repository's configured owner.
            dependencies: ["QualityGateCLI", "QualityGateCore", "QualityGateTestKit", "GateCI"]
        ),

        // The IJS MCP server moved to its own package, `jpurnell/ijs-mcp-server`, on
        // 2026-09-18 (SeparatingTheJudgmentLayer.md §3.3). It had to: roseclub runs macOS
        // 14.8.9 and this package's floor is macOS 15, so the binary built there and then
        // dyld-failed. Nothing in its six files needed macOS 15.
        //
        // It was first *copied* rather than moved, and the two halves diverged within the day —
        // the copy left here kept a defect the new one had fixed. Deleting this target is what
        // the extraction actually was; the duplicate is the whole reason to say so here.

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
