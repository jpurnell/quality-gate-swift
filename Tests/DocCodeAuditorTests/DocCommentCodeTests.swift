import Foundation
import QualityGateCore
import Testing
@testable import DocCodeAuditor

/// End-to-end fixtures for `doc-comment-code`: real Swift files, real `swiftc -typecheck`,
/// real verdicts.
///
/// These compile against the standard library and the SDK only, so they need no built module
/// and no network — what is under test is the auditor's behaviour, not any package's
/// documentation.
///
/// The last test in the file is the one that matters most. An earlier harness in this project
/// reported the same error count for known-good and known-bad code because its flags were
/// being word-split and silently dropped, and it was believed for an hour. A checker that
/// cannot fail is worse than no checker, because it certifies.
@Suite("Doc Comment Code Fixtures", .serialized)
struct DocCommentCodeTests {

    // MARK: - Harness

    /// Extracts the checkable fences from `source` and audits each one exactly as the checker
    /// would — one fence, one program, one compilation.
    private func audit(
        _ source: String, imports: [String] = ["Foundation"], path: String = "Fixture.swift"
    ) throws -> [DocCommentFenceVerdict] {
        var options = DocCodeAuditOptions()
        options.imports = imports
        options.languageFlags = ["-swift-version", "6"]
        return try DocCommentFenceExtractor.fences(in: source, path: path)
            .filter(\.isCheckable)
            .map { try DocCommentFenceAuditor.audit($0, options: options) }
    }

    // MARK: - Must fail

    @Test("A fence calling an initialiser with a label the API never had fails")
    func wrongArgumentLabelFails() throws {
        // The `DistributionNormal(mean:stdDev:)` shape: the type exists, the labels do not.
        // This is the defect class the whole rule family was built for, and the one that is
        // invisible to every checker that only asks whether a doc comment *exists*.
        let verdicts = try audit("""
        /// A measurement.
        public struct Measurement {
            /// Creates one.
            ///
            /// ```swift
            /// let m = Measurement(average: 1.0, spread: 2.0)
            /// ```
            public init(mean: Double, deviation: Double) {}
        }
        """)
        #expect(verdicts.count == 1)
        #expect(verdicts.first?.passed == false)
        #expect(verdicts.first?.compileErrors.isEmpty == false)
        // Line 6 of the file — the call site, not anywhere in the temporary program.
        #expect(verdicts.first?.compileErrors.contains { $0.fileLine == 6 } == true)
    }

    @Test("A fence referencing a symbol nothing defines fails, at the .swift line")
    func undefinedSymbolFails() throws {
        // `cannot find 'config' in scope` — the dominant defect in this repository, ten
        // auditors deep, from one copied `## Usage` template.
        let verdicts = try audit("""
        /// Builds things.
        ///
        /// ## Usage
        ///
        /// ```swift
        /// let checker = Builder()
        /// let result = try await checker.check(configuration: config)
        /// ```
        public struct Builder {}
        """)
        #expect(verdicts.count == 1)
        #expect(verdicts.first?.passed == false)
        // The fence opens at line 5; `config` is named on line 7.
        #expect(verdicts.first?.compileErrors.contains {
            $0.fileLine == 7 && $0.message.contains("config")
        } == true)
    }

    @Test("A fence needing an import its module does not re-export fails")
    func missingImportFails() throws {
        // The `BuildChecker` case, reduced to the standard library. Ten doc comments in this
        // repository demonstrate themselves against a type from a module their own module
        // imports *without* `@_exported`, so a reader who copies the block hits
        // `cannot find … in scope` immediately.
        //
        // **If this test ever passes, someone has widened the preamble**, and §4 of the
        // proposal needs re-reading: a preamble generous enough to make the corpus green is a
        // preamble that certifies documentation the reader cannot use.
        let verdicts = try audit("""
        /// Logs things.
        ///
        /// ```swift
        /// let logger = Logger(subsystem: "com.example", category: "demo")
        /// logger.info("ready")
        /// ```
        public struct Logging {}
        """)
        #expect(verdicts.first?.passed == false)
        #expect(verdicts.first?.compileErrors.contains { $0.message.contains("Logger") } == true)
    }

    @Test("The repair for a missing import is the import line, inside the fence")
    func fenceCarryingItsOwnImportPasses() throws {
        // The other half of the same measurement, and the reason the ungenerous preamble is
        // the right answer: the working repair is a line the reader needs too.
        let verdicts = try audit("""
        /// Logs things.
        ///
        /// ```swift
        /// import os
        ///
        /// let logger = Logger(subsystem: "com.example", category: "demo")
        /// logger.info("ready")
        /// ```
        public struct Logging {}
        """)
        #expect(verdicts.first?.passed == true)
    }

    @Test("A fence importing a module the target cannot reach reports a barrier")
    func unreachableModuleIsABarrier() throws {
        // The `QualityGateTestKit` / `SafetyAuditor` case: the doc comment demonstrates
        // itself against a module the target does not depend on and must not. A
        // `no such module` stops compilation before typechecking, so every error behind it
        // is invisible — reporting it as an ordinary compile error would send the reader to
        // fix a line whose real problem is the build graph.
        let verdicts = try audit("""
        /// A helper.
        ///
        /// ```swift
        /// import ModuleThisTargetDoesNotDependOn
        ///
        /// let helper = Helper()
        /// ```
        public struct Helper {}
        """)
        #expect(verdicts.first?.passed == false)
        // The barrier must name the module that stopped the compilation, not merely exist:
        // its whole purpose is to tell the reader that the error count behind it is
        // meaningless, and a barrier that does not say which import failed cannot do that.
        let barrier = verdicts.first?.barrier ?? ""
        #expect(barrier.contains("ModuleThisTargetDoesNotDependOn"))
        // `no such module` is the one barrier that *does* carry a source location, so it is
        // reported twice on purpose: once as the barrier, and once against the import line
        // the reader has to edit. Line 4 — the fence opens at 3.
        #expect(verdicts.first?.compileErrors.count == 1)
        #expect(verdicts.first?.compileErrors.first?.fileLine == 4)
    }

    // MARK: - Must pass

    @Test("Two fences in one doc comment both binding 'result' both pass")
    func twoFencesSharingANameBothPass() throws {
        // §3's rule, and the fixture that makes the per-fence unit falsifiable. Under any
        // per-doc-comment or per-file compilation unit, one of these is an invalid
        // redeclaration and the checker reports a defect that is not one.
        let verdicts = try audit("""
        /// An auditor.
        ///
        /// ```swift
        /// let result = 1
        /// print(result)
        /// ```
        ///
        /// ## Exemptions
        ///
        /// ```swift
        /// let result = 2
        /// print(result)
        /// ```
        public struct Auditor {}
        """)
        let passing = verdicts.filter(\.passed).count
        #expect(verdicts.count == 2)
        #expect(passing == 2)
    }

    @Test("A fence of bare top-level statements including try await compiles")
    func bareTopLevelStatementsCompile() throws {
        // The `main.swift` decision. Most doc-comment fences are bare statements, and
        // `try await` at file scope only typechecks under the top-level concurrency rules
        // that the file name buys.
        let verdicts = try audit("""
        /// Reads a value.
        ///
        /// ```swift
        /// func load() async throws -> Int { 1 }
        /// let value = try await load()
        /// print(value)
        /// ```
        public struct Reader {}
        """)
        #expect(verdicts.count == 1)
        #expect(verdicts.first?.passed == true)
    }

    @Test("A fence marked illustrative is never compiled, however broken")
    func illustrativeFenceIsNotCompiled() throws {
        let source = """
        /// Documents another package's API.
        ///
        /// <!-- docs:illustrative -->
        /// ```swift
        /// let g = distributionGamma(r: { … }, λ: 2, seed: 7)
        /// #expect(g > 0)
        /// ```
        public struct Tourist {}
        """
        // Nothing is compiled, so nothing can fail — and the census still counts it.
        let verdicts = try audit(source)
        #expect(verdicts.isEmpty)
        let census = DocCommentFenceExtractor.census(in: source, path: "Tourist.swift")
        #expect(census.found == 1)
        #expect(census.checked == 0)
        #expect(census.exempt == 1)
    }

    @Test("A non-Swift fence is never compiled")
    func nonSwiftFenceIsNotCompiled() throws {
        let verdicts = try audit("""
        /// Configured like this:
        ///
        /// ```yaml
        /// excludePatterns:
        ///   - .build
        /// ```
        public struct Config {}
        """)
        #expect(verdicts.isEmpty)
    }

    // MARK: - Line attribution

    @Test("The program is the preamble, a blank line, then the fence body")
    func programShape() {
        let fence = DocCommentFence(
            filePath: "F.swift", openLine: 14, language: "swift",
            body: ["let checker = BuildChecker()"], isExempt: false,
            declarationName: "BuildChecker", accessLevel: "public")
        let program = DocCommentFenceAuditor.program(for: fence, imports: ["Foundation", "BuildChecker"])
        #expect(program == """
            import Foundation
            import BuildChecker

            let checker = BuildChecker()

            """)
    }

    @Test("fileLine = fenceOpenLine + (compiledLine - preambleLineCount)")
    func lineArithmetic() {
        // Verified end to end in the proposal against `BuildChecker.swift`: the fence opens
        // at line 14, the compiler reports line 5 of a 3-line preamble, 14 + (5 - 3) = 16 —
        // which is `/// let result = try await checker.check(configuration: config)`.
        #expect(DocCommentFenceAuditor.fileLine(compiledLine: 5, fenceOpenLine: 14, preambleLines: 3) == 16)
        // The first body line is the line after the fence opener.
        #expect(DocCommentFenceAuditor.fileLine(compiledLine: 4, fenceOpenLine: 14, preambleLines: 3) == 15)
    }

    @Test("A fence on a nested, indented declaration reports the real .swift line")
    func nestedDeclarationLineAttribution() throws {
        let verdicts = try audit("""
        public enum Outer {

            /// An inner helper.
            ///
            /// ```swift
            /// let value = 1
            /// let broken: Int = "not an integer"
            /// ```
            public static func inner() {}
        }
        """)
        #expect(verdicts.count == 1)
        #expect(verdicts.first?.compileErrors.contains { $0.fileLine == 7 } == true)
    }

    // MARK: - Negative control

    @Test("The harness can fail: known-good passes and known-bad does not, in one run")
    func negativeControl() throws {
        // Asserting both halves in one test, because the failure that actually happened was
        // a harness whose flags were dropped and which therefore reported the *same* verdict
        // for both. Either half alone would have looked fine.
        let verdicts = try audit("""
        /// Two examples.
        ///
        /// ```swift
        /// let good: Int = 1
        /// print(good)
        /// ```
        ///
        /// ```swift
        /// struct S: Comparable { let x: Int }
        /// ```
        public struct Control {}
        """)
        #expect(verdicts.count == 2)
        #expect(verdicts.first?.passed == true)
        #expect(verdicts.last?.passed == false)
        #expect(verdicts.last?.compileErrors.isEmpty == false)
    }
}

/// The checker's own wiring: its identity, its posture, and the preamble it refuses to widen.
///
/// None of these needs a toolchain, and all of them are load-bearing decisions that a later
/// convenience could quietly undo.
@Suite("Doc Comment Code Checker")
struct DocCommentCodeAuditorTests {

    @Test("The checker id is its own, not doc-code's")
    func idIsDistinct() {
        // A shared id means the two rules cannot be red and green independently. `doc-code`
        // was made green at real cost; folding sixteen doc-comment failures into the same id
        // would turn it red the day this lands, and a gate that is red on arrival gets
        // skipped.
        #expect(DocCommentCodeAuditor().id == "doc-comment-code")
        #expect(DocCommentCodeAuditor().id != DocCodeAuditor().id)
    }

    @Test("Parallel-safe and hermetic")
    func posture() {
        let auditor = DocCommentCodeAuditor()
        // Parallel-safe for ordering, not for safety: `CheckerRunner` runs non-parallel-safe
        // checkers first, so declaring `true` is what guarantees a finished `.build/debug`.
        #expect(auditor.isParallelSafe)
        #expect(auditor.hermeticity == .hermetic)
    }

    @Test("The preamble is Foundation plus the owning module, and extraImports cannot widen it")
    func preambleIsNotWidenedByConfiguration() {
        // Rejected on measurement, not on taste: injecting `QualityGateCore` would have
        // turned ten failures into ten passes while the examples stayed uncopyable, and it
        // could not have fixed the four `QualityGateTestKit` fences at any depth. A global
        // extra-imports knob here is a suppression with a nicer name.
        var configuration = Configuration()
        configuration.docCode.extraImports = ["QualityGateCore", "SafetyAuditor"]
        let imports = DocCommentCodeAuditor.preambleImports(
            module: "BuildChecker", configuration: configuration)
        #expect(imports == ["Foundation", "BuildChecker"])
    }

    @Test("The owning module is the first path component under Sources/")
    func owningModuleDerivation() {
        let root = URL(fileURLWithPath: "/pkg")
        #expect(DocCommentCodeAuditor.owningModule(
            of: URL(fileURLWithPath: "/pkg/Sources/BuildChecker/BuildChecker.swift"),
            projectRoot: root) == "BuildChecker")
        #expect(DocCommentCodeAuditor.owningModule(
            of: URL(fileURLWithPath: "/pkg/Sources/IJSCore/Detail/Nested.swift"),
            projectRoot: root) == "IJSCore")
        // `Tests/` carries no public API and has no `.swiftmodule` to compile against.
        #expect(DocCommentCodeAuditor.owningModule(
            of: URL(fileURLWithPath: "/pkg/Tests/IJSCoreTests/Nested.swift"),
            projectRoot: root) == nil)
    }
}
