import Foundation
import Testing
import QualityGateCore
@testable import AccessibilityAuditor

/// Which targets the CLI accessibility rules apply to.
///
/// A test that asserts on an escape sequence is not a program emitting one at a user's
/// terminal, so auditing test targets reports the assertion literal as though it were a
/// write. Library and executable targets keep their coverage.
@Suite("AccessibilityAuditor — target scope")
struct AccessibilityTargetScopeTests {

    private let auditor = AccessibilityAuditor()

    /// A file that emits red foreground with no color-preference guard anywhere in it.
    ///
    /// Printed rather than returned — the rules are about output, so a builder that hands
    /// the string back to its caller is deliberately not a finding.
    private static let unguardedColor = #"""
    import SwiftCLIKit

    func paint(_ text: String) {
        print("\u{001B}[31m" + text + "\u{001B}[0m")
    }
    """#

    /// Builds a throwaway SwiftPM layout and returns its root, plus a matching configuration.
    private func makeFixture() throws -> (root: URL, configuration: Configuration) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("A11yTargetScope_\(UUID().uuidString)", isDirectory: true)
            .standardized
        let manager = FileManager.default
        for leaf in ["Sources/Widget", "Tests/WidgetTests"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(leaf, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        var configuration = Configuration()
        configuration.projectRoot = root
        return (root, configuration)
    }

    private func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("A library target's unguarded color is reported")
    func libraryTargetIsAudited() async throws {
        let (root, configuration) = try makeFixture()
        defer { remove(root) }

        let path = root.appendingPathComponent("Sources/Widget/Paint.swift").path
        let result = try await auditor.auditSource(
            Self.unguardedColor, fileName: path, configuration: configuration
        )
        let colorFindings = result.diagnostics.filter { $0.ruleId == "a11y.cli.no-color-not-respected" }
        #expect(colorFindings.count == 1)
    }

    @Test("The same source in a test target is not reported")
    func testTargetIsNotAudited() async throws {
        let (root, configuration) = try makeFixture()
        defer { remove(root) }

        let path = root.appendingPathComponent("Tests/WidgetTests/PaintTests.swift").path
        let result = try await auditor.auditSource(
            Self.unguardedColor, fileName: path, configuration: configuration
        )
        #expect(result.diagnostics.isEmpty)
    }

    @Test("A file that belongs to no target keeps its coverage")
    func unresolvableFileIsAudited() async throws {
        let (root, configuration) = try makeFixture()
        defer { remove(root) }

        let path = root.appendingPathComponent("loose.swift").path
        let result = try await auditor.auditSource(
            Self.unguardedColor, fileName: path, configuration: configuration
        )
        let colorFindings = result.diagnostics.filter { $0.ruleId == "a11y.cli.no-color-not-respected" }
        #expect(colorFindings.count == 1)
    }
}
