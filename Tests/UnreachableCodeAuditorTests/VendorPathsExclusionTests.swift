import Foundation
import Testing
@testable import UnreachableCodeAuditor
@testable import QualityGateCore

/// Verifies the unreachable checker excludes vendored third-party code declared
/// via `vendorPaths` — code the project does not own should not gate it.
@Suite("UnreachableCodeAuditor: vendorPaths exclusion")
struct VendorPathsExclusionTests {

    /// Dead code that trips `unreachable.after_terminator` (an error-severity finding).
    private static let deadCode = """
    func f() -> Int {
        return 1
        let x = 2
        return x
    }
    """

    /// Builds a plain-project tree with a first-party file and a vendored file,
    /// both containing the same dead-code error.
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vendortest-\(UUID().uuidString)", isDirectory: true)
        let firstParty = root.appendingPathComponent("Sources/App/First.swift")
        let vendored = root.appendingPathComponent("vendor-sdk/Sources/Dead.swift")
        for url in [firstParty, vendored] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.deadCode.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("Without vendorPaths, vendored dead code is reported (control)")
    func reportsVendoredByDefault() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await UnreachableCodeAuditor().audit(at: root, configuration: Configuration())
        let vendoredFindings = result.diagnostics.filter {
            $0.ruleId == "unreachable.after_terminator"
                && ($0.filePath?.contains("vendor-sdk") ?? false)
        }
        #expect(!vendoredFindings.isEmpty)
    }

    @Test("With vendorPaths, vendored dead code is excluded but first-party is not")
    func excludesVendoredWhenConfigured() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = Configuration(vendorPaths: ["vendor-sdk"])
        let result = try await UnreachableCodeAuditor().audit(at: root, configuration: config)

        let vendoredFindings = result.diagnostics.filter {
            $0.filePath?.contains("vendor-sdk") ?? false
        }
        #expect(vendoredFindings.isEmpty)

        let firstPartyFindings = result.diagnostics.filter {
            $0.ruleId == "unreachable.after_terminator"
                && ($0.filePath?.contains("Sources/App") ?? false)
        }
        #expect(!firstPartyFindings.isEmpty)
    }
}
