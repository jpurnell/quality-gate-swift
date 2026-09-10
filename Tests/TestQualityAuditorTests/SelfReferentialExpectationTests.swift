import XCTest
@testable import TestQualityAuditor
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// §3.5 — an expected value that recomputes the implementation.
///
/// This rule reports at `error`, on a corpus where it has zero known instances, so its
/// negative fixtures carry more weight than its positive one. Each one below is a shape that
/// looks like the flagged pattern and is a correct test.
final class SelfReferentialExpectationTests: XCTestCase {

    /// Parses `source` and returns the comparison inside the first `#expect`.
    private func comparison(inAssertion source: String) throws -> SemanticTestRules.Comparison {
        let file = Parser.parse(source: source)
        let finder = FirstExpectFinder(viewMode: .sourceAccurate)
        finder.walk(file)
        let macro = try XCTUnwrap(finder.macro, "no #expect found in the fixture")
        let first = try XCTUnwrap(macro.arguments.first?.expression)
        return try XCTUnwrap(
            SemanticTestRules.comparison(in: first), "the assertion is not a comparison")
    }

    private final class FirstExpectFinder: SyntaxVisitor {
        var macro: MacroExpansionExprSyntax?
        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
            if macro == nil, node.macroName.text == "expect" { macro = node }
            return .visitChildren
        }
    }

    /// An index holding one single-expression function, built the way the real one is.
    private func index(_ implementation: String) -> SelfReferentialExpectation.ImplementationIndex {
        var built = SelfReferentialExpectation.ImplementationIndex()
        let file = Parser.parse(source: implementation)
        let collector = BodyProbe(viewMode: .sourceAccurate)
        collector.walk(file)
        for (name, body) in collector.found {
            built.record(name: name, normalizedBody: body)
        }
        return built
    }

    private final class BodyProbe: SyntaxVisitor {
        var found: [(name: String, body: String)] = []
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard let block = node.body, block.statements.count == 1,
                  let only = block.statements.first?.item else { return .visitChildren }
            let expression: ExprSyntax? =
                only.as(ReturnStmtSyntax.self)?.expression ?? only.as(ExprSyntax.self)
            if let expression,
               let shape = SelfReferentialExpectation.normalizedShape(of: expression) {
                found.append((node.name.text, shape))
            }
            return .visitChildren
        }
    }

    /// Parses a bare expression. `ExprSyntax(stringLiteral:)` does not exist in this
    /// SwiftSyntax version, so the expression is parsed as a one-statement file.
    private func parseExpr(_ text: String) throws -> ExprSyntax {
        let file = Parser.parse(source: text)
        let item = try XCTUnwrap(file.statements.first?.item)
        return try XCTUnwrap(item.as(ExprSyntax.self), "not an expression: \(text)")
    }

    // MARK: - The tautology

    func testFlagsExpectedValueThatRestatesTheBody() throws {
        let implementation = "func scaled(_ a: Double, _ b: Double, _ c: Double) -> Double { a * b / c }"
        let assertion = "#expect(scaled(x, y, z) == x * y / z)"

        let restated = SelfReferentialExpectation.restatedFunction(
            in: try comparison(inAssertion: assertion), using: index(implementation))
        XCTAssertEqual(restated, "scaled")
    }

    func testFlagsRestatementWrittenOnTheLeft() throws {
        let implementation = "func scaled(_ a: Double, _ b: Double, _ c: Double) -> Double { a * b / c }"
        let assertion = "#expect(x * y / z == scaled(x, y, z))"

        let restated = SelfReferentialExpectation.restatedFunction(
            in: try comparison(inAssertion: assertion), using: index(implementation))
        XCTAssertEqual(restated, "scaled")
    }

    // MARK: - The shapes that must not fire

    func testAllowsIndependentlyDerivedExpectedValue() throws {
        let implementation = "func scaled(_ a: Double, _ b: Double, _ c: Double) -> Double { a * b / c }"
        // The oracle, not the implementation: a number worked out elsewhere.
        let assertion = "#expect(scaled(2.0, 3.0, 4.0) == 1.5)"

        let restated = SelfReferentialExpectation.restatedFunction(
            in: try comparison(inAssertion: assertion), using: index(implementation))
        XCTAssertNil(restated)
    }

    func testAllowsDifferentShape() throws {
        let implementation = "func scaled(_ a: Double, _ b: Double, _ c: Double) -> Double { a * b / c }"
        let assertion = "#expect(scaled(x, y, z) == x / y * z)"

        let restated = SelfReferentialExpectation.restatedFunction(
            in: try comparison(inAssertion: assertion), using: index(implementation))
        XCTAssertNil(restated, "a different arrangement is an independent claim")
    }

    func testDeclinesToGuessBetweenOverloads() throws {
        let implementation = """
        func scaled(_ a: Double, _ b: Double, _ c: Double) -> Double { a * b / c }
        func scaled(_ a: Int, _ b: Int, _ c: Int) -> Int { a * b / c }
        """
        let assertion = "#expect(scaled(x, y, z) == x * y / z)"

        let restated = SelfReferentialExpectation.restatedFunction(
            in: try comparison(inAssertion: assertion), using: index(implementation))
        XCTAssertNil(
            restated,
            "with two candidates there is no way to know which was called")
    }

    func testAllowsSingleOperatorRelation() throws {
        // `double(x) == x + x` states a relation directly. Correct tests do this often, and
        // a one-operator shape is also the most likely to coincide by accident.
        let implementation = "func double(_ x: Double) -> Double { x + x }"
        let assertion = "#expect(double(x) == x + x)"

        let restated = SelfReferentialExpectation.restatedFunction(
            in: try comparison(inAssertion: assertion), using: index(implementation))
        XCTAssertNil(restated)
    }

    func testAllowsUnknownFunction() throws {
        let assertion = "#expect(scaled(x, y, z) == x * y / z)"

        let restated = SelfReferentialExpectation.restatedFunction(
            in: try comparison(inAssertion: assertion),
            using: .empty)
        XCTAssertNil(restated, "an empty index reports nothing at all")
    }

    // MARK: - Normalisation

    func testShapeIsInvariantUnderRenaming() throws {
        let left = try XCTUnwrap(SelfReferentialExpectation.normalizedShape(
            of: try parseExpr("a * b / c")))
        let right = try XCTUnwrap(SelfReferentialExpectation.normalizedShape(
            of: try parseExpr("x * y / z")))
        XCTAssertEqual(left, right)
    }

    func testShapeKeepsLiteralsDistinct() throws {
        let two = try XCTUnwrap(SelfReferentialExpectation.normalizedShape(
            of: try parseExpr("x * 2 + y")))
        let three = try XCTUnwrap(SelfReferentialExpectation.normalizedShape(
            of: try parseExpr("x * 3 + y")))
        XCTAssertNotEqual(
            two, three,
            "pinning a different constant is a different claim, not the same shape")
    }
}
