import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

/// Writes `files` under a fresh package root and returns the root.
private func makePackage(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fallback-auditor-\(UUID().uuidString)")
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

private let guardedConversion = """
func year(tenor: Double) -> Int {
    guard abs(tenor) < 1e15 else { return 0 }
    return Int(tenor)
}

"""

/// A default configuration pointed at `root`.
private func configuration(at root: URL) -> Configuration {
    var configuration = Configuration()
    configuration.projectRoot = root
    return configuration
}

// MARK: - Tests

@Suite("FallbackAuditor")
struct FallbackAuditorTests {

    @Test("Checker identity properties")
    func identity() {
        let auditor = FallbackAuditor()
        #expect(auditor.id == "fallback")
        #expect(auditor.name == "Fallback Auditor")
        #expect(auditor.category == .correctness)
        #expect(auditor.kind == .code)
        #expect(auditor.effect == .readOnly)
        #expect(auditor.executesProjectCode == false)
    }

    @Test("An unguarded conversion in Sources fails the check")
    func failsOnUnguardedConversion() async throws {
        let root = try makePackage(["Sources/Curves/Curve.swift": unguardedConversion])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(result.checkerId == "fallback")
        #expect(result.status == .failed)
        let findings = result.diagnostics.filter { $0.ruleId == FallbackRuleID.intConversionUnguarded }
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 2)
        #expect(findings.first?.filePath?.hasSuffix("Sources/Curves/Curve.swift") == true)
    }

    @Test("A guarded conversion passes, and the run still says what it examined")
    func passesAndReportsCoverage() async throws {
        let root = try makePackage([
            "Sources/Curves/Curve.swift": guardedConversion,
            "Sources/Curves/Other.swift": "let answer = 42\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(result.status == .passed)
        let coverage = result.diagnostics.filter { $0.ruleId == FallbackRuleID.coverage }
        #expect(coverage.count == 1)
        #expect(coverage.first?.severity == .note)
        #expect(coverage.first?.message.contains("examined 2 files") == true)
        #expect(coverage.first?.message.contains("1 integer conversion") == true)
    }

    @Test("A conversion in Tests is not production code")
    func ignoresTestDirectory() async throws {
        let root = try makePackage(["Tests/CurveTests/CurveTests.swift": unguardedConversion])
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover temp directory is not a test failure

        let result = try await FallbackAuditor().check(configuration: configuration(at: root))

        #expect(result.status == .passed)
        #expect(result.diagnostics.filter { $0.ruleId == FallbackRuleID.intConversionUnguarded }.isEmpty)
    }

    @Test("auditSource reports a single file without touching the filesystem")
    func auditsSourceString() async throws {
        let result = try await FallbackAuditor().auditSource(
            unguardedConversion,
            fileName: "Sources/Curves/Curve.swift",
            configuration: Configuration()
        )
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
    }
}
