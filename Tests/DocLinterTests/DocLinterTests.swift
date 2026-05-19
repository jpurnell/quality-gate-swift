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
        #expect(diagnostics.first?.filePath == "/path/to/Sources/Module/File.swift")
        #expect(diagnostics.first?.lineNumber == 10)
        #expect(diagnostics.first?.columnNumber == 5)
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

    // MARK: - Library Target Auto-Detection Tests

    @Test("Detects library target from Package.swift content")
    func detectsLibraryTarget() {
        let packageContent = """
        let package = Package(
            name: "my-project",
            products: [
                .library(
                    name: "MyLib",
                    targets: ["MyLib"]
                ),
            ],
            targets: [
                .target(name: "MyLib"),
                .testTarget(name: "MyLibTests", dependencies: ["MyLib"]),
            ]
        )
        """

        let target = DocLinter.parseLibraryTarget(from: packageContent)
        #expect(target == "MyLib")
    }

    @Test("Detects first library target when multiple products exist")
    func detectsFirstLibraryTarget() {
        let packageContent = """
        let package = Package(
            name: "multi-lib",
            products: [
                .library(name: "Core", targets: ["Core"]),
                .library(name: "Utils", targets: ["Utils"]),
                .executable(name: "CLI", targets: ["CLI"]),
            ],
            targets: [
                .target(name: "Core"),
                .target(name: "Utils"),
                .executableTarget(name: "CLI"),
            ]
        )
        """

        let target = DocLinter.parseLibraryTarget(from: packageContent)
        #expect(target == "Core")
    }

    @Test("Returns nil when no library products exist")
    func returnsNilForNoLibrary() {
        let packageContent = """
        let package = Package(
            name: "cli-only",
            products: [
                .executable(name: "mytool", targets: ["mytool"]),
            ],
            targets: [
                .executableTarget(name: "mytool"),
            ]
        )
        """

        let target = DocLinter.parseLibraryTarget(from: packageContent)
        #expect(target == nil)
    }

    @Test("Returns nil for empty content")
    func returnsNilForEmptyContent() {
        let target = DocLinter.parseLibraryTarget(from: "")
        #expect(target == nil)
    }

    @Test("Resolves explicit docTarget over auto-detection")
    func explicitDocTargetTakesPrecedence() {
        let packageContent = """
        let package = Package(
            name: "my-project",
            products: [
                .library(name: "AutoDetected", targets: ["AutoDetected"]),
            ],
            targets: [.target(name: "AutoDetected")]
        )
        """

        let resolved = DocLinter.resolveDocTarget(
            configured: "ExplicitTarget",
            packageContent: packageContent
        )
        #expect(resolved == "ExplicitTarget")
    }

    @Test("Falls back to auto-detection when docTarget is nil")
    func fallsBackToAutoDetection() {
        let packageContent = """
        let package = Package(
            name: "my-project",
            products: [
                .library(name: "MyLib", targets: ["MyLib"]),
            ],
            targets: [.target(name: "MyLib")]
        )
        """

        let resolved = DocLinter.resolveDocTarget(
            configured: nil,
            packageContent: packageContent
        )
        #expect(resolved == "MyLib")
    }

    // MARK: - Parameter Name Extraction Tests

    @Test("Extracts parameter name from missing-documentation message")
    func extractsParamNameMissingDoc() {
        let name = DocLinter.extractParameterName(
            from: "Parameter 'config' is missing documentation"
        )
        #expect(name == "config")
    }

    @Test("Extracts parameter name from not-found message")
    func extractsParamNameNotFound() {
        let name = DocLinter.extractParameterName(
            from: "Parameter 'expertFiles' not found in instance method declaration"
        )
        #expect(name == "expertFiles")
    }

    @Test("Returns nil for non-parameter message")
    func returnsNilForNonParameterMessage() {
        let name = DocLinter.extractParameterName(
            from: "Symbol 'foo' is undocumented"
        )
        #expect(name == nil)
    }

    // MARK: - Diagnostic Location Enrichment Tests

    @Test("Enriches parameter diagnostic with source location")
    func enrichesParameterDiagnostic() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocLinterTest-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyLib")
        try FileManager.default.createDirectory(
            at: sourcesDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceContent = """
        /// A greeter.
        public struct Greeter {
            /// Greets someone.
            public func greet(config: Config, name: String) {
                print("hello")
            }
        }
        """
        try sourceContent.write(
            to: sourcesDir.appendingPathComponent("Greeter.swift"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "Parameter 'config' is missing documentation",
                ruleId: "docc"
            )
        ]

        let enriched = DocLinter.enrichDiagnosticsWithLocations(
            diagnostics,
            sourceRoot: tmpDir.path
        )

        #expect(enriched.count == 1)
        #expect(enriched[0].filePath?.contains("Greeter.swift") == true)
        #expect(enriched[0].lineNumber == 4)
        #expect(enriched[0].message == "Parameter 'config' is missing documentation")
    }

    @Test("Finds parameter in multiline function signature")
    func findsParameterInMultilineSignature() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocLinterTest-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyLib")
        try FileManager.default.createDirectory(
            at: sourcesDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceContent = """
        /// Processes data.
        public func process(
            input: Data,
            config: Configuration,
            verbose: Bool
        ) -> Result {
            fatalError()
        }
        """
        try sourceContent.write(
            to: sourcesDir.appendingPathComponent("Processor.swift"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "Parameter 'config' is missing documentation",
                ruleId: "docc"
            )
        ]

        let enriched = DocLinter.enrichDiagnosticsWithLocations(
            diagnostics,
            sourceRoot: tmpDir.path
        )

        #expect(enriched.count == 1)
        #expect(enriched[0].filePath?.contains("Processor.swift") == true)
        #expect(enriched[0].lineNumber == 4)
    }

    @Test("Does not modify diagnostics that already have locations")
    func preservesExistingLocations() {
        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "Parameter 'x' is missing documentation",
                filePath: "/existing/path.swift",
                lineNumber: 42,
                ruleId: "docc"
            )
        ]

        let enriched = DocLinter.enrichDiagnosticsWithLocations(
            diagnostics,
            sourceRoot: "/nonexistent"
        )

        #expect(enriched[0].filePath == "/existing/path.swift")
        #expect(enriched[0].lineNumber == 42)
    }

    @Test("Distributes multiple locations for same parameter name")
    func distributesMultipleLocations() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocLinterTest-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyLib")
        try FileManager.default.createDirectory(
            at: sourcesDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceContent = """
        /// First function.
        public func alpha(config: Config) {}

        /// Second function.
        public func beta(config: Config) {}
        """
        try sourceContent.write(
            to: sourcesDir.appendingPathComponent("Funcs.swift"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "Parameter 'config' is missing documentation",
                ruleId: "docc"
            ),
            Diagnostic(
                severity: .warning,
                message: "Parameter 'config' is missing documentation",
                ruleId: "docc"
            ),
        ]

        let enriched = DocLinter.enrichDiagnosticsWithLocations(
            diagnostics,
            sourceRoot: tmpDir.path
        )

        #expect(enriched[0].filePath?.contains("Funcs.swift") == true)
        #expect(enriched[1].filePath?.contains("Funcs.swift") == true)
        #expect(enriched[0].lineNumber == 2)
        #expect(enriched[1].lineNumber == 5)
    }

    @Test("Finds doc-comment parameter for not-found warnings")
    func findsDocCommentParameter() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocLinterTest-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyLib")
        try FileManager.default.createDirectory(
            at: sourcesDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceContent = """
        /// Does something.
        ///
        /// - Parameter expertFiles: The files to use.
        public func doStuff(files: [URL]) {}
        """
        try sourceContent.write(
            to: sourcesDir.appendingPathComponent("Stuff.swift"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "Parameter 'expertFiles' not found in instance method declaration",
                ruleId: "docc"
            )
        ]

        let enriched = DocLinter.enrichDiagnosticsWithLocations(
            diagnostics,
            sourceRoot: tmpDir.path
        )

        #expect(enriched[0].filePath?.contains("Stuff.swift") == true)
        #expect(enriched[0].lineNumber == 3)
    }

    // MARK: - Symbol Reference Extraction Tests

    @Test("Extracts symbol reference from doesn't-exist message")
    func extractsSymbolReference() {
        let ref = DocLinter.extractSymbolReference(
            from: "'CheckResult' doesn't exist at '/QualityGateCore/OverrideProcessor'"
        )
        #expect(ref?.symbol == "CheckResult")
        #expect(ref?.contextPath == "/QualityGateCore/OverrideProcessor")
    }

    @Test("Extracts symbol reference with method context")
    func extractsSymbolReferenceWithMethod() {
        let ref = DocLinter.extractSymbolReference(
            from: "'CheckResult' doesn't exist at '/QualityGateCore/OverrideProcessor/apply(to:)'"
        )
        #expect(ref?.symbol == "CheckResult")
        #expect(ref?.contextPath == "/QualityGateCore/OverrideProcessor/apply(to:)")
    }

    @Test("Returns nil for non-symbol-reference message")
    func returnsNilForNonSymbolMessage() {
        let ref = DocLinter.extractSymbolReference(
            from: "Parameter 'config' is missing documentation"
        )
        #expect(ref == nil)
    }

    // MARK: - Symbol Reference Location Enrichment Tests

    @Test("Enriches symbol-reference diagnostic with source location")
    func enrichesSymbolReferenceDiagnostic() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocLinterTest-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/QualityGateCore")
        try FileManager.default.createDirectory(
            at: sourcesDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceContent = """
        /// Applies overrides to a result.
        ///
        /// Processes each ``CheckResult`` and filters diagnostics.
        public struct OverrideProcessor {
            /// Applies overrides.
            ///
            /// - Parameter result: The ``CheckResult`` to process.
            public func apply(to result: CheckResult) -> CheckResult {
                result
            }
        }
        """
        try sourceContent.write(
            to: sourcesDir.appendingPathComponent("OverrideProcessor.swift"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "'CheckResult' doesn't exist at '/QualityGateCore/OverrideProcessor'",
                ruleId: "docc"
            ),
            Diagnostic(
                severity: .warning,
                message: "'CheckResult' doesn't exist at '/QualityGateCore/OverrideProcessor/apply(to:)'",
                ruleId: "docc"
            ),
        ]

        let enriched = DocLinter.enrichDiagnosticsWithLocations(
            diagnostics,
            sourceRoot: tmpDir.path
        )

        #expect(enriched[0].filePath?.contains("OverrideProcessor.swift") == true)
        #expect(enriched[0].lineNumber == 3)
        #expect(enriched[1].filePath?.contains("OverrideProcessor.swift") == true)
        #expect(enriched[1].lineNumber == 7)
    }

    @Test("Enriches symbol-reference using single backtick format")
    func enrichesSingleBacktickSymbolRef() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocLinterTest-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyModule")
        try FileManager.default.createDirectory(
            at: sourcesDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceContent = """
        /// Converts a `Widget` to output.
        public func convert() {}
        """
        try sourceContent.write(
            to: sourcesDir.appendingPathComponent("Converter.swift"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "'Widget' doesn't exist at '/MyModule/convert()'",
                ruleId: "docc"
            )
        ]

        let enriched = DocLinter.enrichDiagnosticsWithLocations(
            diagnostics,
            sourceRoot: tmpDir.path
        )

        #expect(enriched[0].filePath?.contains("Converter.swift") == true)
        #expect(enriched[0].lineNumber == 1)
    }
}
