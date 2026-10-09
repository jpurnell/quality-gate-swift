import FloatingPointSafetyAuditor
import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Converts one XCTest file to Swift Testing, and says what it could not convert.
///
/// The conversion works on the syntax tree rather than the text. Both converters written
/// before this one were text-based. One rewrote a class declaration inside a test's fixture
/// string (`1edc66e`); the other turned `testRepeat` into the keyword `repeat`. A string
/// literal is a single token here, and a token is only renamed where the tree says it is a
/// name.
///
/// ## Checked before anything is written
///
/// A conversion is only offered for writing if four things hold (see ``Outcome``):
/// - **No test is orphaned.** XCTest discovers tests by name, Swift Testing by attribute. A
///   `func test*` that loses its way to `@Test` does not fail; it stops running.
/// - **The output parses.**
/// - **Nothing in the file needed a decision.** An expectation, a `measure` block, an
///   `XCTSkip` in a helper: each has more than one Swift Testing form, and which one depends
///   on what the test meant. Such a file is declined whole, and ``Outcome/declines`` names
///   each construct and its line. Converting the rest and leaving those in place was tried:
///   the file no longer imported XCTest, so it did not compile.
/// - **The output does not contain the finding the gate would report next.** A converted
///   `XCTAssertEqual` on `Double` is `#expect(a == b)`, which `exact-double-equality`
///   rejects. The gate's own detector is run over the output, and each site it flags becomes
///   `a.isEqual(to: b)`: the exact claim `XCTAssertEqual` made, now named, never loosened.
///   `TestQualityAuditor.fix` then runs every other test-quality rule over the result and
///   declines a file that would gain a finding.
enum XCTestMigration {

    /// One file's conversion.
    struct Outcome: Sendable {
        /// The converted source.
        let output: String
        /// Why the file cannot be converted, one finding per construct, at its line in the
        /// input. Empty when it can.
        let declines: [Diagnostic]
        /// `func test*()` methods in `XCTestCase` subclasses, before.
        let testsBefore: Int
        /// `@Test` functions the conversion added.
        let testsAfter: Int
        /// Whether the output parses without errors.
        let parses: Bool

        /// The orphan check, the parse check, and nothing declined.
        var isSafeToWrite: Bool { parses && testsAfter == testsBefore && declines.isEmpty }
    }

    /// Converts `source`, reporting what stops it against `fileName`.
    static func migrate(source: String, fileName: String) -> Outcome {
        let tree = Parser.parse(source: source)
        let analysis = MigrationAnalysis(tree: tree, fileName: fileName)
        let converted = MigrationRenderer(analysis: analysis).render(Syntax(tree))
        let named = namingExactFloatComparisons(in: converted, fileName: fileName)

        let outputTree = Parser.parse(source: named)
        return Outcome(
            output: named,
            declines: analysis.declines.sorted {
                ($0.lineNumber ?? 0, $0.columnNumber ?? 0) < ($1.lineNumber ?? 0, $1.columnNumber ?? 0)
            },
            testsBefore: analysis.testMethodCount,
            testsAfter: testAttributeCount(outputTree) - testAttributeCount(tree),
            parses: !outputTree.hasError)
    }

    // MARK: - Verification

    private static func testAttributeCount(_ tree: SourceFileSyntax) -> Int {
        TestAttributeCounter(viewMode: .sourceAccurate).count(in: tree)
    }

    // MARK: - Self-consistency with the gate

    /// Rewrites each exact float comparison the gate would flag into a named comparison.
    ///
    /// Asks `FloatingPointRules`, the detector `exact-double-equality` itself uses, rather
    /// than guessing at types: a conversion that disagreed with the gate about what is a
    /// float would hand back a file the gate rejects.
    private static func namingExactFloatComparisons(in source: String, fileName: String) -> String {
        let tree = Parser.parse(source: source)
        let findings = FloatingPointRules.audit(
            source: source,
            fileName: fileName,
            options: .testAssertions(extraSuppressionMarkers: []),
            parsedTree: tree
        ).diagnostics
        guard !findings.isEmpty else { return source }

        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let optionalFunctions = OptionalReturningFunctions(viewMode: .sourceAccurate).names(in: tree)
        var edits: [(range: Range<Int>, text: String)] = []
        for finding in findings {
            guard let line = finding.lineNumber, let column = finding.columnNumber else { continue }
            let position = converter.position(ofLine: line, column: column)
            guard let edit = NamedComparison.edit(
                at: position, in: tree, elementwise: finding.message.contains("collections"),
                optionalFunctions: optionalFunctions)
            else { continue }
            if !edits.contains(where: { $0.range.overlaps(edit.range) }) {
                edits.append(edit)
            }
        }
        var bytes = Array(source.utf8)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Functions this file declares as returning an optional, by base name.
private final class OptionalReturningFunctions: SyntaxVisitor {
    private var found: Set<String> = []

    func names(in tree: SourceFileSyntax) -> Set<String> {
        found = []
        walk(tree)
        return found
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let returned = node.signature.returnClause?.type,
           returned.is(OptionalTypeSyntax.self) || returned.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            found.insert(node.name.text)
        }
        return .visitChildren
    }
}

/// Counts functions carrying `@Test`.
private final class TestAttributeCounter: SyntaxVisitor {
    private var total = 0

    func count(in tree: SourceFileSyntax) -> Int {
        total = 0
        walk(tree)
        return total
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.attributes.contains(where: { $0.as(AttributeSyntax.self)?.isNamed("Test") == true }) {
            total += 1
        }
        return .visitChildren
    }
}

extension AttributeSyntax {
    /// Whether this attribute is `@name`, ignoring arguments.
    func isNamed(_ name: String) -> Bool {
        attributeName.trimmedDescription == name
    }
}
