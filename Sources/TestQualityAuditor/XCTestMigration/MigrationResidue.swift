import SwiftSyntax

/// The XCTest constructs the conversion leaves in place, and what to tell the person who has to
/// decide for them.
///
/// Each of these has more than one correct Swift Testing form, and which one depends on what
/// the test meant. `XCTSkip` is the clearest case. In the SwiftExcelFunctions migration, 32 of
/// 39 skips were a helper giving up on a value it did not expect, which is a failure. The
/// other 7 were a missing private corpus, which is an `.enabled(if:)` trait. A fixer that
/// always picked one form would have been silently wrong on 7 sites, or on 32.
enum MigrationResidue {

    /// What to say about `node`, if it names a construct the conversion leaves for a person.
    static func note(for node: DeclReferenceExprSyntax) -> String? {
        let name = node.baseName.text
        switch name {
        case "XCTSkip", "XCTSkipIf", "XCTSkipUnless":
            return "\(name): decide whether this test does not apply here (an `.enabled(if:)` trait on the test) or has found a failure (throw an error, or `Issue.record`). XCTSkip is often the second, written as the first."
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

    private static func call(_ node: DeclReferenceExprSyntax) -> FunctionCallExprSyntax? {
        guard let call = node.parent?.as(FunctionCallExprSyntax.self),
              call.calledExpression.id == ExprSyntax(node).id
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
