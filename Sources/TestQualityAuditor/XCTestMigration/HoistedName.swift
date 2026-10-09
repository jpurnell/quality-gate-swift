import SwiftSyntax

/// Names for the values the conversion binds ahead of an assertion.
///
/// `#expect` and `#require` cannot hold everything an `XCTAssert*` call could: a mutating call,
/// a `#require` inside a `#require`, a fallback the gate rejects. Each of those is bound to a
/// `let` on the line before, and the binding needs a name that reads as what it holds and
/// collides with nothing.
enum HoistedName {

    /// A name for the value of `expression`, taken from the last thing it mentions.
    ///
    /// `q.next()` is `next`, `URL(string: s)` is `url`, `rows[1]` is `rowsElement`, and a bare
    /// reference `x` is `xValue`, because `x` is already taken by `x`.
    static func base(for expression: ExprSyntax) -> String {
        var core = Operand.strip(expression).expression
        var suffix = "Value"
        // Peel down to the member or reference that names the value. Each step is a strict
        // child of the last, so the loop ends at a leaf.
        while let step = inner(of: core) {
            core = step.expression
            suffix = step.suffix ?? suffix
        }
        if let member = core.as(MemberAccessExprSyntax.self) {
            return lowered(member.declName.baseName.text)
        }
        if let reference = core.as(DeclReferenceExprSyntax.self) {
            return lowered(reference.baseName.text) + suffix
        }
        return "value"
    }

    /// What `expression` is a call, subscript, unwrap or parenthesisation of, and the suffix
    /// that says so. `nil` at a member, a reference, or anything with no name in it.
    private static func inner(of expression: ExprSyntax) -> (expression: ExprSyntax, suffix: String?)? {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return (call.calledExpression, "")
        }
        if let subscripted = expression.as(SubscriptCallExprSyntax.self) {
            return (subscripted.calledExpression, "Element")
        }
        if let chained = expression.as(OptionalChainingExprSyntax.self) {
            return (chained.expression, nil)
        }
        if let forced = expression.as(ForceUnwrapExprSyntax.self) {
            return (forced.expression, nil)
        }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let only = tuple.elements.first {
            return (Operand.strip(only.expression).expression, nil)
        }
        return nil
    }

    /// `URL` → `url`, `Thing` → `thing`; a name that is not an identifier becomes `value`.
    private static func lowered(_ name: String) -> String {
        guard let first = name.first, first.isLetter || first == "_" else { return "value" }
        return TestNameLowering.lowerLeadingWord(name)
    }

    /// Hands out names no declaration or reference in the file already uses.
    struct Allocator {
        private var taken: Set<String>

        /// - Parameter taken: Every name the file declares or refers to.
        init(taken: Set<String>) {
            self.taken = taken.union(TestNameLowering.keywords)
        }

        /// `base` if it is free, else `base2`, `base3`, and so on.
        mutating func fresh(_ base: String) -> String {
            var name = base
            var suffix = 2
            while taken.contains(name) {
                name = base + String(suffix)
                suffix += 1
            }
            taken.insert(name)
            return name
        }
    }
}
