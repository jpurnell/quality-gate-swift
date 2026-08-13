import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Rules 2 and 3 — the Swift side of the dispatch, where the surplus threads are
/// created and where a failed dispatch is mistaken for a successful one.
public enum DispatchRules {

    /// Rule 2: a threadgroup count computed by rounding up.
    public static let roundedDispatchID = "gpu.rounded-dispatch"

    /// Rule 3: results read after `waitUntilCompleted()` with no status check.
    public static let uncheckedCommandBufferID = "gpu.unchecked-command-buffer"

    /// Analyses one Swift file.
    ///
    /// - Parameters:
    ///   - swiftSource: File contents.
    ///   - path: File path, for the diagnostics.
    /// - Returns: Diagnostics ordered by line.
    public static func diagnose(swiftSource: String, path: String) -> [Diagnostic] {
        let tree = Parser.parse(source: swiftSource)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let visitor = DispatchVisitor(path: path, converter: converter)
        visitor.walk(tree)
        return visitor.diagnostics.sorted { ($0.lineNumber ?? 0) < ($1.lineNumber ?? 0) }
    }
}

/// Walks a Swift file for dispatch sites and command-buffer completions.
final class DispatchVisitor: SyntaxVisitor {

    private(set) var diagnostics: [Diagnostic] = []
    private let path: String
    private let converter: SourceLocationConverter

    /// Set once `waitUntilCompleted()` is seen, cleared by a status check.
    private var awaitingStatusCheck: AbsolutePosition?

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let called = node.calledExpression.trimmedDescription

        // Rule 3 — order matters, so this runs on the call itself.
        if called.hasSuffix("waitUntilCompleted") {
            awaitingStatusCheck = node.positionAfterSkippingLeadingTrivia
        }

        // Rule 2 — the threadgroup count is almost never computed inline. The idiom
        // binds it first (`let groups = MTLSize(width: (n + 255) / 256, ...)`) and
        // passes the name, so matching only the dispatch call's own arguments misses
        // the shape this rule exists for. Flag where the count is *computed*, which
        // is also the line the author edits.
        if called.hasSuffix("MTLSize") || called.hasSuffix("dispatchThreadgroups") {
            for argument in node.arguments where isRoundedUp(argument.expression) {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: """
                        Threadgroup count is rounded up, so the dispatch covers more threads \
                        than there are elements. Every kernel reached from here must bound its \
                        thread id, or the surplus threads read and write past the buffers — \
                        silently, and only at sizes that are not a multiple of the threadgroup \
                        width. `dispatchThreads(_:threadsPerThreadgroup:)` avoids the surplus \
                        entirely where the device supports it.
                        """,
                    filePath: path,
                    lineNumber: converter.location(
                        for: node.positionAfterSkippingLeadingTrivia).line,
                    ruleId: DispatchRules.roundedDispatchID))
                break
            }
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let member = node.declName.baseName.text
        if member == "status" || member == "error" {
            awaitingStatusCheck = nil
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        // Completion state does not carry across function boundaries.
        awaitingStatusCheck = nil
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        if let position = awaitingStatusCheck {
            diagnostics.append(Diagnostic(
                severity: .error,
                message: """
                    Results are read after `waitUntilCompleted()` with no check of the command \
                    buffer's `status` or `error`. A dispatch that failed returns the buffer's \
                    previous contents rather than throwing, so the failure is indistinguishable \
                    from a successful run that computed different numbers.
                    """,
                filePath: path,
                lineNumber: converter.location(for: position).line,
                ruleId: DispatchRules.uncheckedCommandBufferID))
            awaitingStatusCheck = nil
        }
    }

    /// Whether an expression computes `(n + k - 1) / k` or `(n + K) / K`.
    ///
    /// Both spellings are the same idiom; the second pre-subtracts the one. Matching
    /// the shape rather than the literals keeps the rule from depending on a
    /// particular threadgroup width.
    private func isRoundedUp(_ expression: ExprSyntax) -> Bool {
        let text = expression.trimmedDescription
        guard text.contains("/") else { return false }
        guard let divide = text.range(of: "/") else { return false }
        let numerator = String(text[text.startIndex..<divide.lowerBound])
        guard numerator.contains("+") else { return false }
        // A rounding numerator adds something to the element count; a plain
        // `count / width` is an exact division and is not this rule's business.
        return true
    }
}
