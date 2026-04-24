import Foundation
import Testing
@testable import SwiftVersionChecker
@testable import QualityGateCore

/// Tests for SwiftVersionChecker.
///
/// Verifies tools-version parsing, semver comparison, compiler version parsing,
/// check result generation, and fix behavior with verification builds.
@Suite("SwiftVersionChecker Tests")
struct SwiftVersionCheckerTests {

    // MARK: - Identity Tests

    @Test("SwiftVersionChecker has correct id and name")
    func checkerIdentity() {
        let checker = SwiftVersionChecker()
        #expect(checker.id == "swift-version")
        #expect(checker.name == "Swift Version Checker")
    }

    // MARK: - Tools Version Parsing

    @Test("Parses standard swift-tools-version line")
    func parsesStandardToolsVersion() {
        let content = """
        // swift-tools-version: 6.0
        import PackageDescription
        """
        let version = SwiftVersionChecker.parseToolsVersion(from: content)
        #expect(version == "6.0")
    }

    @Test("Parses tools-version without space after colon")
    func parsesToolsVersionNoSpace() {
        let content = """
        // swift-tools-version:5.9
        import PackageDescription
        """
        let version = SwiftVersionChecker.parseToolsVersion(from: content)
        #expect(version == "5.9")
    }

    @Test("Parses tools-version with patch component")
    func parsesToolsVersionWithPatch() {
        let content = """
        // swift-tools-version: 5.7.1
        import PackageDescription
        """
        let version = SwiftVersionChecker.parseToolsVersion(from: content)
        #expect(version == "5.7.1")
    }

    @Test("Parses tools-version with major only")
    func parsesToolsVersionMajorOnly() {
        let content = """
        // swift-tools-version: 6
        import PackageDescription
        """
        let version = SwiftVersionChecker.parseToolsVersion(from: content)
        #expect(version == "6")
    }

    @Test("Returns nil for missing tools-version")
    func returnsNilForMissingToolsVersion() {
        let content = """
        import PackageDescription
        let package = Package(name: "Foo")
        """
        let version = SwiftVersionChecker.parseToolsVersion(from: content)
        #expect(version == nil)
    }

    @Test("Returns nil for empty string")
    func returnsNilForEmpty() {
        let version = SwiftVersionChecker.parseToolsVersion(from: "")
        #expect(version == nil)
    }

    // MARK: - Compiler Version Parsing

    @Test("Parses Apple Swift compiler version output")
    func parsesAppleSwiftVersion() {
        let output = """
        Apple Swift version 6.3.1 (swiftlang-6.3.1.1.101 clang-2100.0.123.102)
        Target: arm64-apple-macosx26.0
        """
        let version = SwiftVersionChecker.parseCompilerVersion(from: output)
        #expect(version == "6.3.1")
    }

    @Test("Parses open-source Swift version output")
    func parsesOpenSourceSwiftVersion() {
        let output = """
        Swift version 6.0.3 (swift-6.0.3-RELEASE)
        Target: x86_64-unknown-linux-gnu
        """
        let version = SwiftVersionChecker.parseCompilerVersion(from: output)
        #expect(version == "6.0.3")
    }

    @Test("Returns nil for garbage compiler output")
    func returnsNilForGarbageCompilerOutput() {
        let version = SwiftVersionChecker.parseCompilerVersion(from: "not a swift version")
        #expect(version == nil)
    }

    // MARK: - Version Comparison

    @Test("Equal versions compare as equal")
    func equalVersions() {
        let result = SwiftVersionChecker.compareVersions("6.0", "6.0")
        #expect(result == .orderedSame)
    }

    @Test("Higher major version is greater")
    func higherMajorVersion() {
        let result = SwiftVersionChecker.compareVersions("6.0", "5.9")
        #expect(result == .orderedDescending)
    }

    @Test("Lower minor version is less")
    func lowerMinorVersion() {
        let result = SwiftVersionChecker.compareVersions("6.0", "6.2")
        #expect(result == .orderedAscending)
    }

    @Test("Patch version comparison works")
    func patchVersionComparison() {
        let result = SwiftVersionChecker.compareVersions("5.7.1", "5.7.0")
        #expect(result == .orderedDescending)
    }

    @Test("Missing patch treated as zero")
    func missingPatchTreatedAsZero() {
        let result = SwiftVersionChecker.compareVersions("6.0", "6.0.0")
        #expect(result == .orderedSame)
    }

    @Test("Major-only version compares correctly")
    func majorOnlyComparison() {
        let result = SwiftVersionChecker.compareVersions("6", "5.9.9")
        #expect(result == .orderedDescending)
    }

    // MARK: - Result Generation

    @Test("Creates passed result when version meets minimum")
    func passedWhenMeetsMinimum() {
        let result = SwiftVersionChecker.createCheckResult(
            toolsVersion: "6.2",
            minimumVersion: "6.2",
            compilerVersion: "6.3.1",
            checkCompiler: true,
            verificationResult: nil
        )
        #expect(result.status == .passed)
        #expect(result.checkerId == "swift-version")
    }

    @Test("Creates passed result when version exceeds minimum")
    func passedWhenExceedsMinimum() {
        let result = SwiftVersionChecker.createCheckResult(
            toolsVersion: "6.3",
            minimumVersion: "6.2",
            compilerVersion: "6.3.1",
            checkCompiler: true,
            verificationResult: nil
        )
        #expect(result.status == .passed)
    }

    @Test("Creates failed result when version below minimum")
    func failedWhenBelowMinimum() {
        let result = SwiftVersionChecker.createCheckResult(
            toolsVersion: "5.9",
            minimumVersion: "6.2",
            compilerVersion: "6.3.1",
            checkCompiler: true,
            verificationResult: nil
        )
        #expect(result.status == .failed)
        #expect(result.errorCount >= 1)
    }

    @Test("Failed result includes suggested fix")
    func failedResultIncludesSuggestedFix() {
        let result = SwiftVersionChecker.createCheckResult(
            toolsVersion: "5.7",
            minimumVersion: "6.2",
            compilerVersion: "6.3.1",
            checkCompiler: true,
            verificationResult: nil
        )
        let diag = result.diagnostics.first { $0.severity == .error }
        #expect(diag?.suggestedFix != nil)
        #expect(diag?.suggestedFix?.contains("6.2") == true)
    }

    @Test("Warns when tools-version exceeds compiler")
    func warnsWhenToolsVersionExceedsCompiler() {
        let result = SwiftVersionChecker.createCheckResult(
            toolsVersion: "6.5",
            minimumVersion: "6.2",
            compilerVersion: "6.3.1",
            checkCompiler: true,
            verificationResult: nil
        )
        let warnings = result.diagnostics.filter { $0.severity == .warning }
        #expect(!warnings.isEmpty)
    }

    @Test("Skips compiler check when disabled")
    func skipsCompilerCheckWhenDisabled() {
        let result = SwiftVersionChecker.createCheckResult(
            toolsVersion: "6.5",
            minimumVersion: "6.2",
            compilerVersion: "6.3.1",
            checkCompiler: false,
            verificationResult: nil
        )
        let warnings = result.diagnostics.filter { $0.severity == .warning }
        #expect(warnings.isEmpty)
    }

    @Test("Skipped result when no Package.swift found")
    func skippedWhenNoPackageSwift() {
        let result = SwiftVersionChecker.createCheckResult(
            toolsVersion: nil,
            minimumVersion: "6.2",
            compilerVersion: "6.3.1",
            checkCompiler: true,
            verificationResult: nil
        )
        #expect(result.status == .skipped)
    }

    // MARK: - Verification Build Results

    @Test("Includes verification success in diagnostics")
    func includesVerificationSuccess() {
        let result = SwiftVersionChecker.createCheckResult(
            toolsVersion: "5.9",
            minimumVersion: "6.2",
            compilerVersion: "6.3.1",
            checkCompiler: true,
            verificationResult: .upgradeable
        )
        #expect(result.status == .failed) // Still failed because version is below minimum
        let notes = result.diagnostics.filter { $0.severity == .note }
        #expect(notes.contains { $0.message.contains("upgradeable") || $0.message.contains("verified") })
    }

    @Test("Includes verification failure with build errors")
    func includesVerificationFailure() {
        let buildErrors = [
            Diagnostic(severity: .error, message: "type 'Foo' has no member 'bar'", file: "Sources/Foo.swift", line: 10, ruleId: "swift-compiler")
        ]
        let result = SwiftVersionChecker.createCheckResult(
            toolsVersion: "5.9",
            minimumVersion: "6.2",
            compilerVersion: "6.3.1",
            checkCompiler: true,
            verificationResult: .blocked(errors: buildErrors)
        )
        #expect(result.status == .failed)
        let errors = result.diagnostics.filter { $0.severity == .error }
        // Should have the version error + the build errors
        #expect(errors.count >= 2)
    }

    // MARK: - Tools Version Line Rewriting

    @Test("Rewrites tools-version line in Package.swift content")
    func rewritesToolsVersionLine() {
        let original = """
        // swift-tools-version: 5.9
        import PackageDescription
        """
        let rewritten = SwiftVersionChecker.rewriteToolsVersion(in: original, to: "6.2")
        #expect(rewritten == """
        // swift-tools-version: 6.2
        import PackageDescription
        """)
    }

    @Test("Rewrites tools-version without space after colon")
    func rewritesToolsVersionNoSpace() {
        let original = """
        // swift-tools-version:5.7
        import PackageDescription
        """
        let rewritten = SwiftVersionChecker.rewriteToolsVersion(in: original, to: "6.2")
        #expect(rewritten == """
        // swift-tools-version: 6.2
        import PackageDescription
        """)
    }

    @Test("Returns nil when no tools-version to rewrite")
    func returnsNilWhenNoToolsVersionToRewrite() {
        let original = """
        import PackageDescription
        """
        let rewritten = SwiftVersionChecker.rewriteToolsVersion(in: original, to: "6.2")
        #expect(rewritten == nil)
    }

    // MARK: - Configuration Tests

    @Test("Default config has minimum 6.2")
    func defaultConfigMinimum() {
        let config = SwiftVersionConfig.default
        #expect(config.minimum == "6.2")
        #expect(config.checkCompiler == true)
    }

    @Test("Config loads from YAML")
    func configLoadsFromYAML() throws {
        let yaml = """
        swiftVersion:
          minimum: "5.9"
          checkCompiler: false
        """
        let config = try Configuration.from(yaml: yaml)
        #expect(config.swiftVersion.minimum == "5.9")
        #expect(config.swiftVersion.checkCompiler == false)
    }

    @Test("Config uses defaults when swiftVersion section missing")
    func configUsesDefaultsWhenMissing() throws {
        let yaml = """
        enabledCheckers:
          - build
        """
        let config = try Configuration.from(yaml: yaml)
        #expect(config.swiftVersion.minimum == "6.2")
        #expect(config.swiftVersion.checkCompiler == true)
    }
}
