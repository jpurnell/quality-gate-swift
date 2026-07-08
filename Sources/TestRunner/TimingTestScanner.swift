import Foundation
import SwiftSyntax
import SwiftParser

/// Finds test functions tagged with a `// TIMING:` marker — the self-identifying stress
/// candidates (teardown-liveness bounds, reconnect budgets, phase-sync).
///
/// AST-based so the marker is recognized only as a *comment* attached to a test function:
/// the same text inside a string literal (`@Test("… // TIMING: …")`) or a trailing
/// body comment does not tag anything.
public enum TimingTestScanner {

    /// Returns the function names of test functions carrying `marker` in their leading
    /// trivia, in source order.
    ///
    /// A test function is one attributed `@Test` (Swift Testing) or named `test…` (XCTest).
    ///
    /// - Parameters:
    ///   - source: Swift source text.
    ///   - marker: The comment marker (default `// TIMING:`).
    /// - Returns: The tagged functions' base names.
    public static func timingTests(in source: String, marker: String = "// TIMING:") -> [String] {
        let tree = Parser.parse(source: source)
        let visitor = TimingVisitor(marker: marker, viewMode: .sourceAccurate)
        visitor.walk(tree)
        return visitor.tagged
    }
}

private final class TimingVisitor: SyntaxVisitor {
    let marker: String
    private(set) var tagged: [String] = []

    init(marker: String, viewMode: SyntaxTreeViewMode) {
        self.marker = marker
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard isTestFunction(node) else { return .visitChildren }
        // The leading trivia of the decl spans everything from the previous token up to
        // the first attribute/`func` — so a `// TIMING:` comment on the line(s) above is
        // here, while a body/string occurrence is not.
        if node.leadingTrivia.description.contains(marker) {
            tagged.append(node.name.text)
        }
        return .visitChildren
    }

    private func isTestFunction(_ node: FunctionDeclSyntax) -> Bool {
        if node.name.text.hasPrefix("test") { return true }
        for element in node.attributes {
            if let attribute = element.as(AttributeSyntax.self),
               attribute.attributeName.trimmedDescription == "Test" {
                return true
            }
        }
        return false
    }
}
