import Foundation
import Testing
@testable import DocLinter
@testable import QualityGateCore

/// Tests for DocLinter.
///
/// DocLinter runs `swift package generate-documentation` and parses
/// the output for documentation warnings and errors.
@Suite("DocLinter Tests")
struct DocLinterTests {

    // MARK: - Identity Tests

    @Test("DocLinter has correct id and name")
    func checkerIdentity() {
        let linter = DocLinter()
        #expect(linter.id == "doc-lint")
        #expect(linter.name == "Documentation Linter")
    }

    // MARK: - Output Parsing Tests

    @Test("Parses documentation warning")
    func parsesDocWarning() {
        let output = """
        warning: 'MyType' doesn't exist at '/MyModule/MyType'
        """

        let diagnostics = DocLinter.parseDocCOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
        #expect(diagnostics.first?.message.contains("doesn't exist") == true)
    }

    @Test("Parses documentation error")
    func parsesDocError() {
        let output = """
        error: Unable to resolve topic reference 'BadLink'
        """

        let diagnostics = DocLinter.parseDocCOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .error)
    }

    @Test("Parses multiple issues")
    func parsesMultipleIssues() {
        let output = """
        warning: 'Foo' doesn't exist at '/Module/Foo'
        warning: 'Bar' doesn't exist at '/Module/Bar'
        error: Unable to resolve 'Baz'
        """

        let diagnostics = DocLinter.parseDocCOutput(output)

        #expect(diagnostics.count == 3)
        #expect(diagnostics.filter { $0.severity == .warning }.count == 2)
        #expect(diagnostics.filter { $0.severity == .error }.count == 1)
    }

    @Test("Handles clean documentation output")
    func handlesCleanOutput() {
        let output = """
        Building documentation for 'MyModule'...
        Finished building documentation for 'MyModule' (0.5s)
        """

        let diagnostics = DocLinter.parseDocCOutput(output)

        #expect(diagnostics.isEmpty)
    }

    @Test("Handles empty output")
    func handlesEmptyOutput() {
        let diagnostics = DocLinter.parseDocCOutput("")
        #expect(diagnostics.isEmpty)
    }

    @Test("Ignores progress messages")
    func ignoresProgressMessages() {
        let output = """
        Building for debugging...
        [1/10] Compiling Module file.swift
        warning: Symbol 'foo' is undocumented
        Build complete!
        """

        let diagnostics = DocLinter.parseDocCOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
    }

    @Test("Parses file location when present")
    func parsesFileLocation() {
        let output = """
        /path/to/Sources/Module/File.swift:10:5: warning: No documentation for 'myFunc'
        """

        let diagnostics = DocLinter.parseDocCOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.file == "/path/to/Sources/Module/File.swift")
        #expect(diagnostics.first?.line == 10)
        #expect(diagnostics.first?.column == 5)
    }

    // MARK: - Result Generation Tests

    @Test("Returns passed status for clean docs")
    func passedForCleanDocs() {
        let result = DocLinter.createResult(
            output: "Finished building documentation",
            exitCode: 0,
            duration: .seconds(1)
        )

        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Returns failed status for doc errors")
    func failedForDocErrors() {
        let output = """
        error: Unable to resolve topic reference
        """

        let result = DocLinter.createResult(
            output: output,
            exitCode: 1,
            duration: .seconds(1)
        )

        #expect(result.status == .failed)
    }

    @Test("Returns passed with warnings")
    func passedWithWarnings() {
        // Warnings don't fail the build, but are reported
        let output = """
        warning: Symbol undocumented
        Finished building documentation
        """

        let result = DocLinter.createResult(
            output: output,
            exitCode: 0,
            duration: .seconds(1)
        )

        #expect(result.status == .passed)
        #expect(result.diagnostics.count == 1)
    }

    @Test("Result includes checkerId")
    func resultIncludesCheckerId() {
        let result = DocLinter.createResult(
            output: "",
            exitCode: 0,
            duration: .seconds(1)
        )

        #expect(result.checkerId == "doc-lint")
    }

    // MARK: - Configuration Tests

    @Test("Generates arguments for specific target")
    func generatesTargetArguments() {
        let config = Configuration(docTarget: "MyModule")
        let linter = DocLinter()

        let args = linter.docArguments(for: config)

        #expect(args.contains("--target"))
        #expect(args.contains("MyModule"))
    }

    @Test("Uses default arguments when no target specified")
    func usesDefaultArguments() {
        let config = Configuration()
        let linter = DocLinter()

        let args = linter.docArguments(for: config)

        // Should not include --target without configuration
        #expect(!args.contains("--target"))
    }
}
