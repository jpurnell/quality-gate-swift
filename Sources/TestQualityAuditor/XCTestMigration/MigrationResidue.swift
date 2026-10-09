import SwiftSyntax

/// The XCTest constructs that stop a file's conversion, and what to tell the person who has to
/// decide for them.
///
/// Each of these has more than one correct Swift Testing form, and which one depends on what
/// the test meant. `XCTSkip` is the clearest case. In the SwiftExcelFunctions migration, 32 of
/// 39 skips were a helper giving up on a value it did not expect, which is a failure. The
/// other 7 were a missing private corpus, which is an `.enabled(if:)` trait. A fixer that
/// always picked one form would have been silently wrong on 7 sites, or on 32.
///
/// These used to be left in place while the rest of the file was converted. That file no
/// longer imported XCTest, so it did not compile, and the person running `--fix` found out
/// from the compiler. A file holding one of these is now declined whole, with the construct
/// and its line as the reason.
enum MigrationResidue {

    /// What to say about `node`, if it names a construct the conversion has no single form for.
    static func note(for node: DeclReferenceExprSyntax) -> String? {
        let name = node.baseName.text
        switch name {
        case "XCTSkip", "XCTSkipIf", "XCTSkipUnless":
            return "\(name): only a skip that is the first statement of a test, on a condition that does not read the suite's own state, can become an `.enabled(if:)` trait, and this is not one. Decide whether the test does not apply here (a trait on the test, with the condition moved where the trait can evaluate it) or has found a failure (`try #require`, or `Issue.record`). XCTSkip is often the second, written as the first."
        case "expectation" where call(node) == nil:
            // A local the test happened to name `expectation`. The call that made it is the
            // construct, and is reported once, there.
            return nil
        case "expectation", "XCTestExpectation", "XCTNSPredicateExpectation":
            return "\(name): Swift Testing waits with `await` or `confirmation { }`, and which one depends on whether the event is awaited or counted."
        case "fulfillment":
            return "fulfillment: replace the expectation it waits for with `await` or `confirmation { }`."
        case "XCTContext":
            return "XCTContext: Swift Testing has no activities. Fold the steps into the test, or into separate tests."
        case "addTeardownBlock":
            return "addTeardownBlock: move the cleanup into the suite's `deinit`, or a `defer` in the test."
        case "XCTExpectFailure":
            return "XCTExpectFailure: the Swift Testing form is `withKnownIssue { }`, whose closure must contain the failing code."
        case "continueAfterFailure":
            return "continueAfterFailure: Swift Testing always continues after `#expect`. Use `#require` where it should stop."
        case "executionTimeAllowance":
            return "executionTimeAllowance: the Swift Testing form is a `.timeLimit(.minutes(n))` trait."
        case "wait" where isCall(node, withFirstLabel: "for"):
            return "wait(for:): replace the expectations it waits for with `await` or `confirmation { }`."
        case "measure" where isCalledWithTrailingClosure(node):
            return "measure: Swift Testing has no performance measurement. Use a benchmark target, or delete the measurement."
        default:
            return nil
        }
    }

    /// The call `node` is the callee of: `wait(…)`, or `self.wait(…)`.
    ///
    /// Only `self.` counts as a member form. `clock.measure { }` is a method on something
    /// else that happens to share a name with XCTest's.
    private static func call(_ node: DeclReferenceExprSyntax) -> FunctionCallExprSyntax? {
        var callee = ExprSyntax(node)
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id {
            guard member.base?.trimmedDescription == "self" else { return nil }
            callee = ExprSyntax(member)
        }
        guard let call = callee.parent?.as(FunctionCallExprSyntax.self),
              call.calledExpression.id == callee.id
        else { return nil }
        return call
    }

    private static func isCall(_ node: DeclReferenceExprSyntax, withFirstLabel label: String) -> Bool {
        call(node)?.arguments.first?.label?.text == label
    }

    private static func isCalledWithTrailingClosure(_ node: DeclReferenceExprSyntax) -> Bool {
        call(node)?.trailingClosure != nil
    }
}
