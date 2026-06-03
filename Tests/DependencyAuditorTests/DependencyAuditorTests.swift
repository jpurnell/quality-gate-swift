import Foundation
import Testing
@testable import DependencyAuditor
@testable import QualityGateCore

// MARK: - Identity

@Suite("DependencyAuditor: Identity")
struct DependencyAuditorIdentityTests {

    @Test("DependencyAuditor has correct id and name")
    func checkerIdentity() {
        let auditor = DependencyAuditor()
        #expect(auditor.id == "dependency-audit")
        #expect(auditor.name == "Dependency Auditor")
    }
}

// MARK: - Package.resolved Parsing

@Suite("DependencyAuditor: Package.resolved Parsing")
struct PackageResolvedParsingTests {

    @Test("Parses v2/v3 Package.resolved with version pins")
    func parsesVersionPins() throws {
        let json = """
        {
          "originHash": "abc123",
          "pins": [
            {
              "identity": "swift-syntax",
              "kind": "remoteSourceControl",
              "location": "https://github.com/swiftlang/swift-syntax.git",
              "state": { "revision": "abc123", "version": "600.0.1" }
            },
            {
              "identity": "swift-argument-parser",
              "kind": "remoteSourceControl",
              "location": "https://github.com/apple/swift-argument-parser.git",
              "state": { "revision": "def456", "version": "1.3.0" }
            }
          ],
          "version": 3
        }
        """
        let resolved = try DependencyAuditor.parsePackageResolved(json)
        #expect(resolved.pins.count == 2)
        #expect(resolved.pins[0].identity == "swift-syntax")
        #expect(resolved.pins[0].state.version == "600.0.1")
        #expect(resolved.pins[0].state.branch == nil)
        #expect(resolved.pins[1].identity == "swift-argument-parser")
    }

    @Test("Parses Package.resolved with branch pins")
    func parsesBranchPins() throws {
        let json = """
        {
          "pins": [
            {
              "identity": "indexstore-db",
              "kind": "remoteSourceControl",
              "location": "https://github.com/apple/indexstore-db.git",
              "state": { "branch": "main", "revision": "def456" }
            }
          ],
          "version": 3
        }
        """
        let resolved = try DependencyAuditor.parsePackageResolved(json)
        #expect(resolved.pins.count == 1)
        #expect(resolved.pins[0].state.branch == "main")
        #expect(resolved.pins[0].state.version == nil)
    }

    @Test("Parses Package.resolved with revision-only pins")
    func parsesRevisionOnlyPins() throws {
        let json = """
        {
          "pins": [
            {
              "identity": "some-tool",
              "kind": "remoteSourceControl",
              "location": "https://github.com/example/some-tool.git",
              "state": { "revision": "abc123" }
            }
          ],
          "version": 3
        }
        """
        let resolved = try DependencyAuditor.parsePackageResolved(json)
        #expect(resolved.pins.count == 1)
        #expect(resolved.pins[0].state.branch == nil)
        #expect(resolved.pins[0].state.version == nil)
    }

    @Test("Throws on malformed JSON")
    func throwsOnMalformedJSON() {
        let json = "{ this is not json }"
        #expect(throws: Error.self) {
            try DependencyAuditor.parsePackageResolved(json)
        }
    }
}

// MARK: - Branch Pin Detection

@Suite("DependencyAuditor: Branch Pin Detection")
struct BranchPinDetectionTests {

    @Test("Detects branch pins as warnings")
    func detectsBranchPins() {
        let pins: [ResolvedPin] = [
            ResolvedPin(
                identity: "indexstore-db",
                kind: "remoteSourceControl",
                location: "https://github.com/apple/indexstore-db.git",
                state: PinState(branch: "main", revision: "def456", version: nil)
            ),
            ResolvedPin(
                identity: "swift-syntax",
                kind: "remoteSourceControl",
                location: "https://github.com/swiftlang/swift-syntax.git",
                state: PinState(branch: nil, revision: "abc123", version: "600.0.1")
            ),
        ]
        let config = DependencyAuditorConfig()
        let diagnostics = DependencyAuditor.checkBranchPins(pins: pins, config: config)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .warning)
        #expect(diagnostics[0].ruleId == "dep-branch-pin")
        #expect(diagnostics[0].message.contains("indexstore-db"))
        #expect(diagnostics[0].message.contains("main"))
    }

    @Test("No warnings when all pins use version tags")
    func noWarningsForVersionPins() {
        let pins: [ResolvedPin] = [
            ResolvedPin(
                identity: "swift-syntax",
                kind: "remoteSourceControl",
                location: "https://github.com/swiftlang/swift-syntax.git",
                state: PinState(branch: nil, revision: "abc123", version: "600.0.1")
            ),
        ]
        let config = DependencyAuditorConfig()
        let diagnostics = DependencyAuditor.checkBranchPins(pins: pins, config: config)
        #expect(diagnostics.isEmpty)
    }

    @Test("Multiple branch pins produce multiple warnings")
    func multipleBranchPins() {
        let pins: [ResolvedPin] = [
            ResolvedPin(
                identity: "pkg-a",
                kind: "remoteSourceControl",
                location: "https://example.com/a.git",
                state: PinState(branch: "develop", revision: "aaa", version: nil)
            ),
            ResolvedPin(
                identity: "pkg-b",
                kind: "remoteSourceControl",
                location: "https://example.com/b.git",
                state: PinState(branch: "feature/x", revision: "bbb", version: nil)
            ),
        ]
        let config = DependencyAuditorConfig()
        let diagnostics = DependencyAuditor.checkBranchPins(pins: pins, config: config)
        #expect(diagnostics.count == 2)
        #expect(diagnostics.allSatisfy { $0.ruleId == "dep-branch-pin" })
    }
}

// MARK: - Branch Pin Allowlist

@Suite("DependencyAuditor: Branch Pin Allowlist")
struct BranchPinAllowlistTests {

    @Test("Allowlisted branch pin is not flagged")
    func allowlistSuppressesBranchPin() {
        let pins: [ResolvedPin] = [
            ResolvedPin(
                identity: "indexstore-db",
                kind: "remoteSourceControl",
                location: "https://github.com/apple/indexstore-db.git",
                state: PinState(branch: "main", revision: "def456", version: nil)
            ),
        ]
        let config = DependencyAuditorConfig(allowBranchPins: ["indexstore-db"])
        let diagnostics = DependencyAuditor.checkBranchPins(pins: pins, config: config)
        #expect(diagnostics.isEmpty)
    }

    @Test("Allowlist filters only matching identities")
    func allowlistFiltersSelectively() {
        let pins: [ResolvedPin] = [
            ResolvedPin(
                identity: "indexstore-db",
                kind: "remoteSourceControl",
                location: "https://github.com/apple/indexstore-db.git",
                state: PinState(branch: "main", revision: "def456", version: nil)
            ),
            ResolvedPin(
                identity: "other-pkg",
                kind: "remoteSourceControl",
                location: "https://example.com/other.git",
                state: PinState(branch: "develop", revision: "aaa", version: nil)
            ),
        ]
        let config = DependencyAuditorConfig(allowBranchPins: ["indexstore-db"])
        let diagnostics = DependencyAuditor.checkBranchPins(pins: pins, config: config)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("other-pkg"))
    }
}

// MARK: - Package.swift URL Extraction

@Suite("DependencyAuditor: Package.swift Parsing")
struct PackageSwiftParsingTests {

    @Test("Extracts dependency URLs from Package.swift content")
    func extractsDependencyURLs() {
        let content = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MyProject",
            dependencies: [
                .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
                .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.3.0"),
            ],
            targets: []
        )
        """
        let urls = DependencyAuditor.extractPackageURLs(from: content)
        #expect(urls.count == 2)
        #expect(urls.contains("https://github.com/swiftlang/swift-syntax.git"))
        #expect(urls.contains("https://github.com/apple/swift-argument-parser.git"))
    }

    @Test("Returns empty array for Package.swift with no dependencies")
    func noDependencies() {
        let content = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Simple",
            targets: [.executableTarget(name: "Simple")]
        )
        """
        let urls = DependencyAuditor.extractPackageURLs(from: content)
        #expect(urls.isEmpty)
    }

    @Test("Handles single-quoted and double-quoted URLs")
    func handlesQuoteVariants() {
        let content = """
        .package(url: "https://github.com/example/one.git", from: "1.0.0"),
        """
        let urls = DependencyAuditor.extractPackageURLs(from: content)
        #expect(urls.count == 1)
    }
}

// MARK: - Status Logic

@Suite("DependencyAuditor: Status Computation")
struct StatusComputationTests {

    @Test("Error diagnostics produce failed status")
    func errorMeansFailed() {
        let diagnostics = [
            Diagnostic(severity: .error, message: "Package.resolved missing", ruleId: "dep-unresolved"),
        ]
        let status = DependencyAuditor.computeStatus(from: diagnostics)
        #expect(status == .failed)
    }

    @Test("Warning-only diagnostics produce warning status")
    func warningMeansWarning() {
        let diagnostics = [
            Diagnostic(severity: .warning, message: "Branch pin detected", ruleId: "dep-branch-pin"),
        ]
        let status = DependencyAuditor.computeStatus(from: diagnostics)
        #expect(status == .warning)
    }

    @Test("No diagnostics produce passed status")
    func emptyMeansPassed() {
        let diagnostics: [Diagnostic] = []
        let status = DependencyAuditor.computeStatus(from: diagnostics)
        #expect(status == .passed)
    }

    @Test("Mixed errors and warnings produce failed status")
    func mixedMeansFailed() {
        let diagnostics = [
            Diagnostic(severity: .warning, message: "Branch pin", ruleId: "dep-branch-pin"),
            Diagnostic(severity: .error, message: "Unresolved", ruleId: "dep-unresolved"),
        ]
        let status = DependencyAuditor.computeStatus(from: diagnostics)
        #expect(status == .failed)
    }
}

// MARK: - Target Name Extraction

@Suite("DependencyAuditor: Target Name Extraction")
struct TargetNameExtractionTests {

    @Test("Extracts target names from Package.swift content")
    func extractsTargetNames() {
        let content = """
        let package = Package(
            name: "MyProject",
            targets: [
                .target(name: "MyLib", dependencies: []),
                .executableTarget(name: "MyCLI", dependencies: ["MyLib"]),
                .testTarget(name: "MyLibTests", dependencies: ["MyLib"]),
            ]
        )
        """
        let names = DependencyAuditor.extractTargetNames(from: content)
        #expect(names.contains("MyLib"))
        #expect(names.contains("MyCLI"))
        #expect(names.contains("MyLibTests"))
        #expect(names.count == 3)
    }

    @Test("Handles all target factory variants")
    func handlesAllFactoryVariants() {
        let content = """
        let package = Package(
            name: "AllVariants",
            targets: [
                .target(name: "A"),
                .executableTarget(name: "B"),
                .testTarget(name: "C"),
                .plugin(name: "D", capability: .buildTool()),
                .systemLibrary(name: "E"),
                .binaryTarget(name: "F", path: "F.xcframework"),
                .macro(name: "G"),
            ]
        )
        """
        let names = DependencyAuditor.extractTargetNames(from: content)
        #expect(names.count == 7)
        for letter in ["A", "B", "C", "D", "E", "F", "G"] {
            #expect(names.contains(letter))
        }
    }
}

// MARK: - Product Name Extraction

@Suite("DependencyAuditor: Product Name Extraction")
struct ProductNameExtractionTests {

    @Test("Extracts .product(name:) references")
    func extractsProductNames() {
        let content = """
        .target(
            name: "MyLib",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "OtherTarget",
            ]
        )
        """
        let names = DependencyAuditor.extractProductNames(from: content)
        #expect(names.contains("SwiftSyntax"))
        #expect(names.contains("ArgumentParser"))
        #expect(names.count == 2)
    }
}

// MARK: - Import Extraction

@Suite("DependencyAuditor: Import Extraction")
struct ImportExtractionTests {

    @Test("Extracts simple import statements")
    func extractsSimpleImports() {
        let source = """
        import Foundation
        import SwiftUI
        import MyModule

        struct Foo {}
        """
        let imports = DependencyAuditor.extractImports(from: source)
        #expect(imports.count == 3)
        #expect(imports.contains { $0.moduleName == "Foundation" && $0.line == 1 })
        #expect(imports.contains { $0.moduleName == "SwiftUI" && $0.line == 2 })
        #expect(imports.contains { $0.moduleName == "MyModule" && $0.line == 3 })
    }

    @Test("Handles @preconcurrency import")
    func handlesPreconcurrency() {
        let source = """
        @preconcurrency import WatchConnectivity
        import Foundation
        """
        let imports = DependencyAuditor.extractImports(from: source)
        #expect(imports.contains { $0.moduleName == "WatchConnectivity" })
        #expect(imports.contains { $0.moduleName == "Foundation" })
    }

    @Test("Handles @testable import")
    func handlesTestable() {
        let source = """
        @testable import MyLib
        import Testing
        """
        let imports = DependencyAuditor.extractImports(from: source)
        #expect(imports.contains { $0.moduleName == "MyLib" })
        #expect(imports.contains { $0.moduleName == "Testing" })
    }

    @Test("Skips imports inside multi-line string literals")
    func skipsMultilineStringImports() {
        let source = """
        import Foundation

        let code = \"\"\"\n        import FakeModule\n        import AnotherFake\n        \"\"\"

        import SwiftUI
        """
        let imports = DependencyAuditor.extractImports(from: source)
        let moduleNames = imports.map(\.moduleName)
        #expect(moduleNames.contains("Foundation"))
        #expect(moduleNames.contains("SwiftUI"))
        #expect(!moduleNames.contains("FakeModule"))
        #expect(!moduleNames.contains("AnotherFake"))
        #expect(imports.count == 2)
    }

    @Test("Marks canImport-guarded imports")
    func marksCanImportGuarded() {
        let source = """
        import Foundation
        #if canImport(UIKit)
        import UIKit
        #endif
        """
        let imports = DependencyAuditor.extractImports(from: source)
        let uikit = imports.first { $0.moduleName == "UIKit" }
        #expect(uikit?.isCanImportGuarded == true)
        let foundation = imports.first { $0.moduleName == "Foundation" }
        #expect(foundation?.isCanImportGuarded == false)
    }
}

// MARK: - Hallucinated Import Detection

@Suite("DependencyAuditor: Hallucinated Imports")
struct HallucinatedImportTests {

    @Test("Flags import of unknown module")
    func flagsUnknownModule() {
        let sourceFiles: [(path: String, content: String)] = [
            ("Sources/MyLib/File.swift", "import Foundation\nimport NonExistentModule\n")
        ]
        let knownModules: Set<String> = ["Foundation", "MyLib"]
        let diagnostics = DependencyAuditor.checkHallucinatedImports(
            sourceFiles: sourceFiles,
            knownModules: knownModules
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].ruleId == "dep-hallucinated-import")
        #expect(diagnostics[0].severity == .warning)
        #expect(diagnostics[0].message.contains("NonExistentModule"))
    }

    @Test("Allows system framework imports")
    func allowsSystemFrameworks() {
        let sourceFiles: [(path: String, content: String)] = [
            ("Sources/MyLib/File.swift", "import Foundation\nimport UIKit\nimport SwiftUI\n")
        ]
        let knownModules = DependencyAuditor.systemFrameworks
        let diagnostics = DependencyAuditor.checkHallucinatedImports(
            sourceFiles: sourceFiles,
            knownModules: knownModules
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Allows local target imports")
    func allowsLocalTargets() {
        let sourceFiles: [(path: String, content: String)] = [
            ("Sources/MyApp/main.swift", "import MyLib\n")
        ]
        let knownModules: Set<String> = ["MyLib", "Foundation"]
        let diagnostics = DependencyAuditor.checkHallucinatedImports(
            sourceFiles: sourceFiles,
            knownModules: knownModules
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Allows external dependency product imports")
    func allowsExternalProducts() {
        let sourceFiles: [(path: String, content: String)] = [
            ("Sources/MyLib/File.swift", "import SwiftSyntax\nimport ArgumentParser\n")
        ]
        let knownModules: Set<String> = ["SwiftSyntax", "ArgumentParser", "Foundation"]
        let diagnostics = DependencyAuditor.checkHallucinatedImports(
            sourceFiles: sourceFiles,
            knownModules: knownModules
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Reports correct file path and line number")
    func reportsCorrectLocation() {
        let sourceFiles: [(path: String, content: String)] = [
            ("Sources/MyLib/File.swift", "import Foundation\n\nimport Hallucinated\n")
        ]
        let knownModules: Set<String> = ["Foundation"]
        let diagnostics = DependencyAuditor.checkHallucinatedImports(
            sourceFiles: sourceFiles,
            knownModules: knownModules
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].filePath == "Sources/MyLib/File.swift")
        #expect(diagnostics[0].lineNumber == 3)
    }

    @Test("Does not flag canImport-guarded imports")
    func skipsCanImportGuarded() {
        let sourceFiles: [(path: String, content: String)] = [
            ("Sources/MyLib/File.swift", """
            import Foundation
            #if canImport(PolarBleSdk)
            import PolarBleSdk
            #endif
            """)
        ]
        let knownModules: Set<String> = ["Foundation"]
        let diagnostics = DependencyAuditor.checkHallucinatedImports(
            sourceFiles: sourceFiles,
            knownModules: knownModules
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Flags unknown import even with canImport for different module")
    func flagsUnrelatedToCanImport() {
        let sourceFiles: [(path: String, content: String)] = [
            ("Sources/MyLib/File.swift", """
            #if canImport(UIKit)
            import UIKit
            import FakeModule
            #endif
            """)
        ]
        let knownModules: Set<String> = ["Foundation", "UIKit"]
        let diagnostics = DependencyAuditor.checkHallucinatedImports(
            sourceFiles: sourceFiles,
            knownModules: knownModules
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message.contains("FakeModule"))
    }
}

// MARK: - Unresolved Detection

@Suite("DependencyAuditor: Unresolved Detection")
struct UnresolvedDetectionTests {

    @Test("Missing Package.resolved produces error diagnostic")
    func missingResolvedIsError() {
        let diagnostics = DependencyAuditor.checkUnresolved(
            resolvedExists: false,
            resolvedPinCount: 0,
            packageSwiftDependencyCount: 2
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].ruleId == "dep-unresolved")
        #expect(diagnostics[0].message.contains("Package.resolved"))
    }

    @Test("Pin count mismatch produces error diagnostic")
    func pinCountMismatchIsError() {
        let diagnostics = DependencyAuditor.checkUnresolved(
            resolvedExists: true,
            resolvedPinCount: 3,
            packageSwiftDependencyCount: 5
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].ruleId == "dep-unresolved")
        #expect(diagnostics[0].message.contains("out of sync"))
    }

    @Test("Matching counts produce no diagnostics")
    func matchingCountsIsClean() {
        let diagnostics = DependencyAuditor.checkUnresolved(
            resolvedExists: true,
            resolvedPinCount: 3,
            packageSwiftDependencyCount: 3
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Resolved may have more pins than Package.swift direct deps (transitive)")
    func resolvedCanHaveMorePins() {
        let diagnostics = DependencyAuditor.checkUnresolved(
            resolvedExists: true,
            resolvedPinCount: 10,
            packageSwiftDependencyCount: 3
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Resolved with fewer pins than Package.swift deps is flagged")
    func resolvedFewerPinsIsFlagged() {
        let diagnostics = DependencyAuditor.checkUnresolved(
            resolvedExists: true,
            resolvedPinCount: 1,
            packageSwiftDependencyCount: 3
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].ruleId == "dep-unresolved")
    }
}

// MARK: - Package Declared Names Extraction

@Suite("DependencyAuditor: Package Declared Names")
struct PackageDeclaredNamesTests {

    @Test("Extracts name: from .package(name:, url:) declarations")
    func extractsDeclaredNames() {
        let content = """
        let package = Package(
            name: "MyProject",
            dependencies: [
                .package(name: "RxSwift", url: "https://github.com/ReactiveX/RxSwift.git", .exact("6.8.0")),
                .package(name: "SwiftProtobuf", url: "https://github.com/apple/swift-protobuf.git", from: "1.6.0"),
                .package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.2"),
            ]
        )
        """
        let names = DependencyAuditor.extractPackageDeclaredNames(from: content)
        #expect(names.contains("RxSwift"))
        #expect(names.contains("SwiftProtobuf"))
        #expect(!names.contains("Zip"))
        #expect(names.count == 2)
    }
}

// MARK: - Exclude Paths Extraction

@Suite("DependencyAuditor: Exclude Paths")
struct ExcludePathsTests {

    @Test("Extracts exclude paths from target declaration")
    func extractsExcludePaths() {
        let content = """
        .target(
            name: "PolarBleSdk",
            dependencies: ["SwiftProtobuf", "RxSwift"],
            path: "Sources",
            exclude: [
                "Android",
                "iOS/ios-communications/Tests",
                "iOS/ios-communications/Sources/iOSCommunications/Info.plist",
            ]
        )
        """
        let paths = DependencyAuditor.extractExcludePaths(from: content)
        #expect(paths.contains("Android"))
        #expect(paths.contains("iOS/ios-communications/Tests"))
        #expect(paths.contains("iOS/ios-communications/Sources/iOSCommunications/Info.plist"))
    }

    @Test("Returns empty for targets with no exclude")
    func emptyWhenNoExclude() {
        let content = """
        .target(name: "MyLib", dependencies: [])
        """
        let paths = DependencyAuditor.extractExcludePaths(from: content)
        #expect(paths.isEmpty)
    }
}

// MARK: - URL Extraction with name: parameter

@Suite("DependencyAuditor: URL Extraction Variants")
struct URLExtractionVariantsTests {

    @Test("Extracts URLs from .package(name:, url:) format")
    func extractsNamedURLs() {
        let content = """
        let package = Package(
            name: "MyProject",
            dependencies: [
                .package(name: "RxSwift", url: "https://github.com/ReactiveX/RxSwift.git", .exact("6.8.0")),
                .package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.2"),
            ]
        )
        """
        let urls = DependencyAuditor.extractPackageURLs(from: content)
        #expect(urls.count == 2)
        #expect(urls.contains("https://github.com/ReactiveX/RxSwift.git"))
        #expect(urls.contains("https://github.com/marmelroy/Zip.git"))
    }
}

// MARK: - V1 Package.resolved Parsing

@Suite("DependencyAuditor: V1 Package.resolved")
struct V1PackageResolvedTests {

    @Test("Parses v1 format Package.resolved")
    func parsesV1Format() throws {
        let json = """
        {
          "object": {
            "pins": [
              {
                "package": "RxSwift",
                "repositoryURL": "https://github.com/ReactiveX/RxSwift.git",
                "state": {
                  "branch": null,
                  "revision": "abc123",
                  "version": "6.8.0"
                }
              },
              {
                "package": "SwiftProtobuf",
                "repositoryURL": "https://github.com/apple/swift-protobuf.git",
                "state": {
                  "branch": null,
                  "revision": "def456",
                  "version": "1.38.0"
                }
              }
            ]
          },
          "version": 1
        }
        """
        let pins = try #require(DependencyAuditor.parsePackageResolvedV1(json))
        #expect(pins.count == 2)
        #expect(pins[0].identity == "rxswift")
        #expect(pins[0].location == "https://github.com/ReactiveX/RxSwift.git")
        #expect(pins[0].state.version == "6.8.0")
        #expect(pins[1].identity == "swiftprotobuf")
        #expect(pins[1].location == "https://github.com/apple/swift-protobuf.git")
    }

    @Test("parseResolvedPins handles v1 format")
    func parseResolvedPinsHandlesV1() {
        let json = """
        {
          "object": {
            "pins": [
              {
                "package": "Zip",
                "repositoryURL": "https://github.com/marmelroy/Zip.git",
                "state": { "branch": null, "revision": "abc", "version": "2.1.2" }
              }
            ]
          },
          "version": 1
        }
        """
        let pins = DependencyAuditor.parseResolvedPins(from: json)
        #expect(pins.count == 1)
        #expect(pins[0].identity == "zip")
        #expect(pins[0].location == "https://github.com/marmelroy/Zip.git")
    }

    @Test("parseResolvedPins handles v2/v3 format")
    func parseResolvedPinsHandlesV2() {
        let json = """
        {
          "pins": [
            {
              "identity": "swift-syntax",
              "kind": "remoteSourceControl",
              "location": "https://github.com/swiftlang/swift-syntax.git",
              "state": { "revision": "abc", "version": "600.0.1" }
            }
          ],
          "version": 3
        }
        """
        let pins = DependencyAuditor.parseResolvedPins(from: json)
        #expect(pins.count == 1)
        #expect(pins[0].identity == "swift-syntax")
    }
}

// MARK: - Hallucinated Import: C system modules

@Suite("DependencyAuditor: C System Modules")
struct CSystemModuleTests {

    @Test("zlib and CommonCrypto are in systemFrameworks")
    func cSystemModulesIncluded() {
        #expect(DependencyAuditor.systemFrameworks.contains("zlib"))
        #expect(DependencyAuditor.systemFrameworks.contains("CommonCrypto"))
        #expect(DependencyAuditor.systemFrameworks.contains("CCommonCrypto"))
        #expect(DependencyAuditor.systemFrameworks.contains("SQLite3"))
    }
}

// MARK: - Hallucinated Import: Checkout-vended sub-products

@Suite("DependencyAuditor: Checkout Sub-products")
struct CheckoutSubproductTests {

    @Test("Recognises products from .build/checkouts dependency manifests")
    func recognisesCheckoutProducts() throws {
        let tmp = NSTemporaryDirectory()
            .appending("dep-audit-checkout-test-\(ProcessInfo.processInfo.processIdentifier)")
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: tmp) }

        let sourcesDir = (tmp as NSString).appendingPathComponent("Sources/MyApp")
        try fm.createDirectory(atPath: sourcesDir, withIntermediateDirectories: true)

        let checkoutDir = (tmp as NSString)
            .appendingPathComponent(".build/checkouts/swift-numerics")
        try fm.createDirectory(atPath: checkoutDir, withIntermediateDirectories: true)

        let depManifest = """
        let package = Package(
            name: "swift-numerics",
            products: [
                .library(name: "Numerics", targets: ["Numerics"]),
                .library(name: "RealModule", targets: ["RealModule"]),
                .library(name: "ComplexModule", targets: ["ComplexModule"]),
            ],
            targets: [
                .target(name: "Numerics"),
                .target(name: "RealModule"),
                .target(name: "ComplexModule"),
            ]
        )
        """
        try depManifest.write(
            toFile: (checkoutDir as NSString).appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8
        )

        let rootManifest = """
        let package = Package(
            name: "MyApp",
            dependencies: [
                .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
            ],
            targets: [
                .target(name: "MyApp", dependencies: [
                    .product(name: "Numerics", package: "swift-numerics"),
                ]),
            ]
        )
        """
        try rootManifest.write(
            toFile: (tmp as NSString).appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8
        )

        let sourceFile = "import Foundation\nimport RealModule\n"
        try sourceFile.write(
            toFile: (sourcesDir as NSString).appendingPathComponent("main.swift"),
            atomically: true, encoding: .utf8
        )

        let diagnostics = DependencyAuditor.runHallucinatedImportCheck(
            projectRoot: tmp,
            packageSwiftContent: rootManifest,
            pins: [],
            config: DependencyAuditorConfig()
        )

        let hallucinatedImports = diagnostics.filter { $0.ruleId == "dep-hallucinated-import" }
        #expect(hallucinatedImports.isEmpty, "RealModule should be recognised from .build/checkouts")
    }
}
