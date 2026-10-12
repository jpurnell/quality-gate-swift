import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// `ParametersDivideToo`: a type written in a signature is the same evidence as a type written
// on a `let`, and the division rule reads it — for the divisor, and for nothing else.

private let divisionRule = "fp-division-unguarded"
private let equalityRule = "fp-equality"

/// Runs the floating-point rules over `source` through the entry point both checkers use.
private func audit(_ source: String) -> [Diagnostic] {
    FloatingPointRules.audit(
        source: source,
        fileName: "Sources/Example/test.swift",
        options: .sources(checkDivisionGuards: true)
    ).diagnostics
}

/// The 1-based lines of every unguarded-division finding in `source`, in order.
private func divisionLines(_ source: String) -> [Int] {
    audit(source).filter { $0.ruleId == divisionRule }.compactMap(\.lineNumber)
}

extension FPDivisionTests {

    // MARK: - Parameters are divisor evidence (§3.1)

    @Test("A division by a Double parameter is examined whatever its numerator is")
    func flagsParameterDivisor() {
        let code = """
        func f(x: Double, d: Double) -> Double {
            x / d
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("The Guide's first flagged example is flagged")
    func flagsGuideNormalize() {
        let code = """
        func normalize(_ values: [Double], by total: Double) -> [Double] {
            values.map { $0 / total }
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("Every concrete floating-point spelling is read", arguments: ["CGFloat", "Float", "Float80"])
    func flagsOtherFloatingPointParameters(type: String) {
        let code = """
        func f(x: \(type), d: \(type)) -> \(type) {
            x / d
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("/= by a parameter is examined")
    func flagsCompoundDivisionByParameter() {
        let code = """
        func f(_ x: inout Double, d: Double) {
            x /= d
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("An ownership specifier does not hide the type", arguments: ["inout", "borrowing"])
    func flagsAttributedParameter(specifier: String) {
        let code = """
        func f(x: Double, _ d: \(specifier) Double) -> Double {
            x / d
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("A default value changes nothing: the caller can still pass zero")
    func flagsDefaultedParameter() {
        let code = """
        func f(x: Double, d: Double = 1.0) -> Double {
            x / d
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("The internal name is bound, not the argument label")
    func flagsInternalParameterName() {
        let code = """
        func f(_ x: Double, by d: Double) -> Double {
            x / d
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("An initializer's parameters are read")
    func flagsInitializerParameter() {
        let code = """
        struct S {
            var v: Double
            init(x: Double, d: Double) {
                self.v = x / d
            }
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A subscript's parameters are read")
    func flagsSubscriptParameter() {
        let code = """
        struct S {
            subscript(x: Double, d: Double) -> Double {
                x / d
            }
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A typed closure's parameters are read")
    func flagsTypedClosureParameter() {
        let code = """
        let ratio = { (x: Double, d: Double) -> Double in
            x / d
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("A nested function's parameters are read, once")
    func flagsNestedFunctionParameter() {
        let code = """
        func outer() -> Double {
            func inner(a: Double, b: Double) -> Double {
                a / b
            }
            return inner(a: 1, b: 2)
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("Unwrapping an optional parameter does not check it for zero")
    func flagsUnwrappedOptionalParameter() {
        let code = """
        func f(x: Double, d: Double?) -> Double {
            guard let d else { return 0 }
            return x / d
        }
        """
        #expect(divisionLines(code) == [3])
    }

    // MARK: - Guards in the function clear it (§3.4)

    @Test("A guard on the parameter clears the division")
    func exemptGuardedParameter() {
        let code = """
        func f(x: Double, d: Double) -> Double {
            guard d != 0 else { return 0 }
            return x / d
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test(
        "precondition and assert are the contract, written down",
        arguments: ["precondition(d != 0)", "assert(d != 0, \"d\")", "precondition(d > 0, \"d must be positive\")"]
    )
    func exemptAssertedParameter(check: String) {
        let code = """
        func f(x: Double, d: Double) -> Double {
            \(check)
            return x / d
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("A documented precondition is a claim about callers, not a check")
    func flagsDocumentedPreconditionOnly() {
        let code = """
        /// - Precondition: d must be non-zero.
        func f(x: Double, d: Double) -> Double {
            return x / d
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("Finite is not non-zero")
    func flagsFiniteGuardOnly() {
        let code = """
        func f(x: Double, d: Double) -> Double {
            guard d.isFinite else { return 0 }
            return x / d
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A precondition after the division does not protect it")
    func flagsPreconditionAfterDivision() {
        let code = """
        func f(x: Double, d: Double) -> Double {
            let r = x / d
            precondition(d != 0)
            return r
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("An early return on d == 0 clears the division")
    func exemptEarlyReturnOnZero() {
        let code = """
        func f(x: Double, d: Double) -> Double {
            if d == 0 { return 0 }
            return x / d
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("…and without the early return it is flagged, so the test above passes for its reason")
    func flagsWithoutEarlyReturn() {
        let code = """
        func f(x: Double, d: Double) -> Double {
            return x / d
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("A guard in the function clears a division by its parameter inside a closure")
    func exemptGuardedParameterInClosure() {
        let code = """
        func f(xs: [Double], d: Double) -> [Double] {
            guard d != 0 else { return xs }
            return xs.map { $0 / d }
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    // MARK: - What reads the signature (§3.2)

    @Test("A local bound to a parameter carries the parameter's evidence")
    func flagsAliasOfParameter() {
        let code = """
        func f(x: Double, d: Double) -> Double {
            let t = d
            return x / t
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A parameter in the numerator is not evidence for an arithmetic divisor")
    func exemptArithmeticDivisorOfParameters() {
        let code = """
        func f(x: Double, a: Double, b: Double) -> Double {
            x / (a - b)
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("Arithmetic on parameters, bound to a name, is still not evidence")
    func exemptArithmeticLocalOfParameters() {
        let code = """
        func f(x: Double, a: Double, b: Double) -> Double {
            let d = a - b
            return x / d
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("A member of another type is examined through a literal numerator, and not through a parameter")
    func memberDivisorNeedsDirectNumerator() {
        let unseen = """
        func f(x: Double, c: Config) -> Double {
            x / c.scale
        }
        """
        #expect(divisionLines(unseen).isEmpty)

        let seen = """
        func f(c: Config) -> Double {
            100.0 / c.scale
        }
        """
        #expect(divisionLines(seen) == [2])
    }

    @Test("fp-equality does not read a signature")
    func equalityUnmovedByParameters() {
        let code = """
        func f(x: Double, d: Double) -> Bool {
            x == d
        }
        """
        #expect(audit(code).isEmpty)
    }

    // MARK: - Shadowing (§3.3)

    @Test("An Int parameter shadows a file-level Double of the same name")
    func exemptParameterShadowingFileLevel() {
        let code = """
        let scale: Double = 2.0
        func f(a: Int, scale: Int) -> Int {
            a / scale
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("An Int parameter shadows a stored Double property of the same name")
    func exemptParameterShadowingMember() {
        let code = """
        struct S {
            let rate: Double
            func f(total: Int, rate: Int) -> Int {
                total / rate
            }
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("An untyped closure parameter shadows the enclosing function's parameter")
    func exemptUntypedClosureParameterShadowing() {
        let code = """
        func f(x: Double, d: Double) -> Double {
            let g: (Int) -> Int = { d in 10 / d }
            guard d != 0 else { return 0 }
            return x / d + Double(g(2))
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("An inner local annotated Int shadows an outer Double")
    func exemptAnnotatedLocalShadowing() {
        let code = """
        let n: Double = 2.5
        func f() -> Int {
            let n: Int = 3
            return 10 / n
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    // MARK: - Scopes and operators (§3.1, §3.5)

    @Test("A subscript's implicit getter is a scope, and its guard is read")
    func exemptGuardInSubscript() {
        let code = """
        struct S {
            subscript(d: Double) -> Double {
                guard d != 0 else { return 0 }
                return 1.0 / d
            }
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("A declaration of / is division, not a use of it")
    func exemptOperatorDeclaration() {
        let code = """
        struct V {
            var v: Double
            static func / (lhs: V, rhs: Double) -> V {
                V(v: lhs.v / rhs)
            }
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("The same body under an ordinary name is examined")
    func flagsOrdinaryFunctionWithOperatorBody() {
        let code = """
        struct V {
            var v: Double
            static func scaled(_ lhs: V, by rhs: Double) -> V {
                V(v: lhs.v / rhs)
            }
        }
        """
        #expect(divisionLines(code) == [4])
    }

    // MARK: - Boundaries, pinned so that widening them is deliberate (§6)

    @Test("A generic parameter is not read")
    func exemptGenericParameter() {
        let code = """
        func f<T: BinaryFloatingPoint>(x: T, d: T) -> T {
            x / d
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("A typealias is read as spelled")
    func exemptTimeIntervalParameter() {
        let code = """
        func f(x: Double, d: TimeInterval) -> Double {
            x / d
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("A stored property is seen only when declared above its use")
    func storedPropertyVisibilityIsByOrder() {
        let below = """
        struct S {
            func f(x: Double) -> Double {
                x / scale
            }
            let scale: Double
        }
        """
        #expect(divisionLines(below).isEmpty)

        let above = """
        struct S {
            let scale: Double
            func f(x: Double) -> Double {
                x / scale
            }
        }
        """
        #expect(divisionLines(above) == [4])
    }

    @Test("Integer parameters divide as integers")
    func exemptIntegerParameters() {
        let code = """
        func f(a: Int, b: Int) -> Int {
            a / b
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    // MARK: - Negative control

    @Test("An unguarded and a guarded parameter in one file: exactly the unguarded one is reported")
    func negativeControlParameters() {
        let code = """
        func unguarded(x: Double, d: Double) -> Double {
            x / d
        }
        func guarded(x: Double, d: Double) -> Double {
            guard d != 0 else { return 0 }
            return x / d
        }
        """
        #expect(divisionLines(code) == [2])
    }
}

// MARK: - The Guide

/// The Guide's first example of a flagged division was not flagged for as long as the page
/// said it was. This reads the example out of the page itself, so the two cannot part again.
@Suite("FloatingPointSafetyAuditorGuide: the examples it calls flagged are flagged")
struct FPGuideExampleTests {

    private static let guide = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/FloatingPointSafetyAuditor/FloatingPointSafetyAuditor.docc")
        .appendingPathComponent("FloatingPointSafetyAuditorGuide.md")

    /// The fenced Swift block that contains `marker`.
    private func block(containing marker: String) throws -> String {
        let text = try String(contentsOf: Self.guide, encoding: .utf8)
        let blocks = text.components(separatedBy: "```swift\n").dropFirst().compactMap {
            $0.components(separatedBy: "\n```").first
        }
        return try #require(blocks.first { $0.contains(marker) })
    }

    @Test("Both divisions in the 'flagged' block are reported, on the lines the page shows")
    func flaggedBlockIsFlagged() throws {
        let source = try block(containing: "func normalize(_ values: [Double], by total: Double)")
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let parameterLine = try #require(lines.firstIndex { $0.contains("$0 / total") }) + 1
        let annotatedLine = try #require(lines.firstIndex { $0.contains("amount / rate") }) + 1

        let found = FloatingPointRules.audit(
            source: source,
            fileName: "Sources/Example/Guide.swift",
            options: .sources(checkDivisionGuards: true)
        ).diagnostics.filter { $0.ruleId == divisionRule }.compactMap(\.lineNumber)

        #expect(found == [parameterLine, annotatedLine])
    }

    @Test("Nothing in the 'accepted' block is reported")
    func acceptedBlockIsClean() throws {
        let source = try block(containing: "func normalizeGuarded(")
        let found = FloatingPointRules.audit(
            source: source,
            fileName: "Sources/Example/Guide.swift",
            options: .sources(checkDivisionGuards: true)
        ).diagnostics.filter { $0.ruleId == divisionRule }
        #expect(found.isEmpty)
    }
}
