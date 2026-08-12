import Foundation
import Testing
@testable import DocLinter
@testable import QualityGateCore

/// A warning the project under test cannot act on must not sit in its gate as if it could.
///
/// `doc-lint` runs `swift package generate-documentation`, which builds *and* runs DocC in one
/// process, so build-engine chatter and documentation findings arrive interleaved in one stream.
/// The location-less fallback pattern exists for real DocC diagnostics — `warning: 'MyType'
/// doesn't exist at '/MyModule/MyType'` — and cannot be deleted, but applied to build output it
/// promotes a dependency's build-graph complaint into a finding against the project.
@Suite("Doc Lint: dependency build noise")
struct DependencyNoiseTests {

    @Test("A build-graph warning about a dependency artifact is not a project warning")
    func dependencyBuildNoiseIsNotAProjectWarning() throws {
        // The observed line, in full. `mlx-swift` ships a metallib as a resource on a C++
        // target; SwiftPM synthesizes a resource-only bundle, and the codesign task declares it
        // mutates a `Contents/MacOS` that a bundle with no executable never has. Nothing in the
        // project under test participates — the dependency arrives transitively.
        let output = """
        warning: missing creator for mutated node: ('/Users/x/App/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')
        """

        let diagnostics = DocLinter.parseDocCOutput(output)
        let finding = try #require(diagnostics.first)

        #expect(finding.severity == .note)
        #expect(finding.ruleId == "doc-lint.dependency-build-noise")
    }

    @Test("A location-less DocC diagnostic is still a warning — the fallback's real purpose")
    func locationlessDocCDiagnosticStillReported() throws {
        let output = "warning: 'MyType' doesn't exist at '/MyModule/MyType'"

        let diagnostics = DocLinter.parseDocCOutput(output)
        let finding = try #require(diagnostics.first)

        #expect(finding.severity == .warning)
        #expect(finding.ruleId != "doc-lint.dependency-build-noise")
    }

    @Test("A located diagnostic is untouched")
    func locatedDiagnosticIsUnchanged() throws {
        let output = "/Users/x/App/Sources/Foo.swift:12:3: warning: No documentation for 'bar'"

        let diagnostics = DocLinter.parseDocCOutput(output)
        let finding = try #require(diagnostics.first)

        #expect(finding.severity == .warning)
        #expect(finding.lineNumber == 12)
    }

    @Test("A location-less warning naming the project's own tree stays a warning")
    func projectPathIsStillAProjectFinding() throws {
        // The bound on the heuristic: only paths that are *all* inside `.build/` are noise.
        // A message naming real source is the project's business however it is shaped.
        let output = "warning: could not read '/Users/x/App/Sources/Foo.docc/Foo.md'"

        let diagnostics = DocLinter.parseDocCOutput(output)
        let finding = try #require(diagnostics.first)

        #expect(finding.severity == .warning)
    }

    @Test("A message naming both a dependency artifact and project source is the project's")
    func mixedPathsAreNotNoise() throws {
        let output = "warning: '/Users/x/App/.build/out/thing' conflicts with '/Users/x/App/Sources/Foo.swift'"

        let diagnostics = DocLinter.parseDocCOutput(output)
        let finding = try #require(diagnostics.first)

        #expect(finding.severity == .warning)
    }

    @Test("A location-less warning naming no path at all stays a warning")
    func noPathIsStillAWarning() throws {
        let output = "warning: Unable to resolve topic reference"

        let diagnostics = DocLinter.parseDocCOutput(output)
        let finding = try #require(diagnostics.first)

        #expect(finding.severity == .warning)
    }

    @Test("Demoted noise does not count toward the warning total")
    func demotedNoiseDoesNotCountAsAWarning() {
        // The accounting half. The information stays visible; a gate that reads 0 warnings is
        // reachable again for a project whose only remaining finding belongs to a dependency.
        let output = """
        warning: missing creator for mutated node: ('/Users/x/App/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')
        /Users/x/App/Sources/Foo.swift:12:3: warning: No documentation for 'bar'
        """

        let diagnostics = DocLinter.parseDocCOutput(output)

        #expect(diagnostics.count == 2)
        #expect(diagnostics.filter { $0.severity == .warning }.count == 1)
        #expect(diagnostics.filter { $0.severity == .note }.count == 1)
    }
}
