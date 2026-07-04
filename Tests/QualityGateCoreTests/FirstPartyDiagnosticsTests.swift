// FirstPartyDiagnosticsTests.swift
// QualityGateCoreTests

import Testing
import QualityGateTypes
@testable import QualityGateCore

@Suite("First-party diagnostic scoping")
struct FirstPartyDiagnosticsTests {

    @Test("Drops a warning from a dependency checkout")
    func dropsDependencyWarning() {
        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "constexpr if is a C++17 extension",
                filePath: "/repo/.build/checkouts/mlx-swift/Source/Cmlx/kernel.h",
                lineNumber: 108,
                ruleId: "swift-compiler"
            )
        ]
        #expect(diagnostics.scopedToFirstParty().isEmpty)
    }

    @Test("Drops a build-artifact warning whose path is only in the message")
    func dropsArtifactMessageWarning() {
        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "missing creator for mutated node: ('/repo/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')",
                ruleId: "docc"
            )
        ]
        #expect(diagnostics.scopedToFirstParty().isEmpty)
    }

    @Test("Keeps a warning in first-party source")
    func keepsFirstPartyWarning() {
        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "No documentation for 'foo'",
                filePath: "/repo/Sources/MyModule/File.swift",
                lineNumber: 10,
                ruleId: "docc"
            )
        ]
        #expect(diagnostics.scopedToFirstParty().count == 1)
    }

    @Test("Keeps an error even inside a dependency checkout")
    func keepsDependencyError() {
        let diagnostics = [
            Diagnostic(
                severity: .error,
                message: "cannot find type 'Foo' in scope",
                filePath: "/repo/.build/checkouts/somedep/Sources/File.swift",
                lineNumber: 5,
                ruleId: "swift-compiler"
            )
        ]
        #expect(diagnostics.scopedToFirstParty().count == 1)
    }

    @Test("Keeps a first-party note and a warning with no path")
    func keepsFirstPartyNoteAndPathlessWarning() {
        let diagnostics = [
            Diagnostic(severity: .note, message: "Documentation coverage: 100%", ruleId: "doc-coverage-summary"),
            Diagnostic(severity: .warning, message: "Institutional consistency below threshold", ruleId: "consistency")
        ]
        #expect(diagnostics.scopedToFirstParty().count == 2)
    }

    @Test("Preserves order of surviving diagnostics")
    func preservesOrder() {
        let diagnostics = [
            Diagnostic(severity: .warning, message: "first", filePath: "/repo/Sources/A.swift", ruleId: "r"),
            Diagnostic(severity: .warning, message: "dep", filePath: "/repo/.build/checkouts/x/B.swift", ruleId: "r"),
            Diagnostic(severity: .warning, message: "third", filePath: "/repo/Sources/C.swift", ruleId: "r")
        ]
        let kept = diagnostics.scopedToFirstParty()
        #expect(kept.map(\.message) == ["first", "third"])
    }
}
