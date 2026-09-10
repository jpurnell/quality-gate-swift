import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// An expected value that recomputes the implementation.
///
/// ```swift
/// import Testing
///
/// // The implementation, in Sources/:
/// func scaled(_ a: Double, _ b: Double, _ c: Double) -> Double { a * b / c }
///
/// let (x, y, z) = (2.0, 3.0, 4.0)
/// #expect(scaled(x, y, z) == x * y / z)
/// ```
///
/// The assertion restates the function's body, so it holds for whatever the body happens to
/// be. Change `*` to `+` in both places and the test still passes; the test is pinned to the
/// code rather than to the intent, which is the one thing a test exists not to be.
///
/// This is the tautology class, and unlike everything else in `SemanticTestRules` it has no
/// legitimate form. That is why it reports at `error` while noisier rules report at
/// `warning`.
///
/// ## Why this one needs `Sources/`
///
/// Every other semantic rule is a property of the test file alone. This one is a statement
/// about the *relationship* between an assertion and a body that lives in another file, so
/// it reads `Sources/` the way `PropertyCoverage` already does. The index is built once per
/// run and shared across every test file.
///
/// ## Deliberately narrow
///
/// The proposal measured zero occurrences and proposed the rule anyway, on the grounds that
/// its absence in one corpus is not evidence of its absence elsewhere. A rule that fires at
/// `error` on zero known instances has to be conservative about what it claims, so every one
/// of these conditions must hold:
///
/// - The comparison is `==`, with a call on exactly one side.
/// - The callee resolves to **exactly one** function in `Sources/`. Overloads are skipped
///   rather than guessed at — with two candidates there is no way to know which was called.
/// - That function's body is a single expression, so "the implementation" is unambiguous.
/// - The shapes match after renaming, and the shape has at least two operators.
///
/// The last condition is what keeps `#expect(double(x) == x + x)` from being reported for a
/// one-operator body: too many correct tests state a simple relation directly, and a simple
/// relation is also the most likely to coincide.
enum SelfReferentialExpectation {

    /// The rule's identifier.
    static let ruleId = "self-referential-expectation"

    /// Single-expression function bodies in `Sources/`, keyed by function name.
    ///
    /// A name maps to every body declared under it. More than one means the name is
    /// overloaded, and the rule declines to guess.
    struct ImplementationIndex: Sendable {
        private var bodiesByName: [String: [String]] = [:]

        /// An empty index. Every lookup misses, so the rule reports nothing.
        static let empty = ImplementationIndex()

        /// The normalized body for a name, or `nil` if unknown or overloaded.
        func normalizedBody(of name: String) -> String? {
            guard let bodies = bodiesByName[name], bodies.count == 1 else { return nil }
            return bodies.first
        }

        /// Records a function's single-expression body.
        mutating func record(name: String, normalizedBody: String) {
            bodiesByName[name, default: []].append(normalizedBody)
        }

        /// How many names the index holds — reported in the rule's coverage note.
        var count: Int { bodiesByName.count }
    }

    // MARK: - Building the index

    /// Indexes every single-expression function body under a package's source roots.
    static func buildIndex(projectRoot: String) -> ImplementationIndex {
        var index = ImplementationIndex()
        let manager = FileManager.default

        for spelling in ["Sources", "Source", "src"] {
            let root = URL(fileURLWithPath: projectRoot).appendingPathComponent(spelling)
            guard let walker = manager.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in walker where url.pathExtension == "swift" {
                guard !url.path.contains(".build/"), !url.path.contains(".docc/") else {
                    continue
                }
                guard let text = SourceFileReader.read(url, checker: "test-quality") else {
                    continue
                }
                let collector = SingleExpressionBodyCollector(viewMode: .sourceAccurate)
                collector.walk(Parser.parse(source: text))
                for (name, body) in collector.bodies {
                    index.record(name: name, normalizedBody: body)
                }
            }
        }
        return index
    }

    /// Collects `func name(…) -> T { <one expression> }` declarations.
    private final class SingleExpressionBodyCollector: SyntaxVisitor {
        var bodies: [(name: String, body: String)] = []

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard let block = node.body,
                  block.statements.count == 1,
                  let only = block.statements.first?.item else {
                return .visitChildren
            }

            // Both spellings of a single-expression body: `{ a * b }` and `{ return a * b }`.
            let expression: ExprSyntax?
            if let returned = only.as(ReturnStmtSyntax.self) {
                expression = returned.expression
            } else {
                expression = only.as(ExprSyntax.self)
            }

            if let expression, let shape = normalizedShape(of: expression) {
                bodies.append((node.name.text, shape))
            }
            return .visitChildren
        }
    }

    // MARK: - Matching

    /// Whether an assertion's expected side restates the implementation of the call on the
    /// other side.
    ///
    /// - Parameters:
    ///   - comparison: The comparison inside `#expect`.
    ///   - index: Single-expression bodies from `Sources/`.
    /// - Returns: The name of the function being restated, or `nil`.
    static func restatedFunction(
        in comparison: SemanticTestRules.Comparison,
        using index: ImplementationIndex
    ) -> String? {
        guard comparison.op == "==" else { return nil }

        // A call on one side, the expected expression on the other. Either order.
        if let name = calleeName(comparison.lhs),
           let restated = matches(expected: comparison.rhs, callee: name, index: index) {
            return restated
        }
        if let name = calleeName(comparison.rhs),
           let restated = matches(expected: comparison.lhs, callee: name, index: index) {
            return restated
        }
        return nil
    }

    /// Whether the expected expression has the same shape as the callee's body.
    private static func matches(
        expected: ExprSyntax,
        callee: String,
        index: ImplementationIndex
    ) -> String? {
        guard let body = index.normalizedBody(of: callee),
              let expectedShape = normalizedShape(of: expected),
              expectedShape == body,
              operatorCount(in: expectedShape) >= 2 else {
            return nil
        }
        return callee
    }

    /// The name of the function a call expression invokes, if it is a plain call.
    private static func calleeName(_ expr: ExprSyntax) -> String? {
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return nil }
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }

    /// An expression rewritten so that only its *structure* remains.
    ///
    /// Identifiers become `$0`, `$1`, … in order of first appearance, so `a * b / c` and
    /// `x * y / z` normalize alike — this is the "up to renaming" the proposal asks for.
    /// Literals are kept verbatim, because `x * 2` and `x * 3` are genuinely different
    /// claims and collapsing them would report a test that pins a constant the
    /// implementation does not contain.
    ///
    /// Returns `nil` for anything containing a nested call, which would make "the same
    /// shape" a much weaker statement than it sounds.
    static func normalizedShape(of expr: ExprSyntax) -> String? {
        let renamer = ShapeRenamer(viewMode: .sourceAccurate)
        renamer.walk(expr)
        guard !renamer.sawCall else { return nil }
        guard !renamer.pieces.isEmpty else { return nil }
        return renamer.pieces.joined(separator: " ")
    }

    /// How many operator tokens a normalized shape contains.
    private static func operatorCount(in shape: String) -> Int {
        shape.split(separator: " ").filter { piece in
            piece.allSatisfy { "+-*/%<>=!&|^~".contains($0) }
        }.count
    }

    /// Flattens an expression into placeholder-and-operator pieces.
    private final class ShapeRenamer: SyntaxVisitor {
        var pieces: [String] = []
        var sawCall = false
        private var names: [String: String] = [:]

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            sawCall = true
            return .skipChildren
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            pieces.append(placeholder(for: node.baseName.text))
            return .visitChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            // `point.x` is one leaf, named by its whole path, so `a.x * a.y` does not
            // collapse into the same shape as `a * b`.
            pieces.append(placeholder(for: node.trimmedDescription))
            return .skipChildren
        }

        override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            pieces.append(node.operator.text)
            return .visitChildren
        }

        override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            pieces.append(node.operator.text)
            return .visitChildren
        }

        override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            pieces.append(node.literal.text)
            return .visitChildren
        }

        override func visit(_ node: FloatLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            pieces.append(node.literal.text)
            return .visitChildren
        }

        private func placeholder(for name: String) -> String {
            if let existing = names[name] { return existing }
            let fresh = "$\(names.count)"
            names[name] = fresh
            return fresh
        }
    }
}
