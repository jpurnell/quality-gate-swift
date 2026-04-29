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
