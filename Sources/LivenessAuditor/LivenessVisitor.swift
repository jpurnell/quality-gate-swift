import Foundation
import QualityGateCore
import SwiftSyntax

/// A blocking primitive that offers a bounded overload, and the overload it offers.
///
/// Membership is decided by one question — *does the vendor's API provide a deadline for this
/// call?* — which is why a finding is never arguable: the overload set is the specification, not
/// an opinion about the code.
///
/// `NSLock` is deliberately absent despite offering `lock(before:)`. Every `lock()` in this
/// repository is the conventional `lock(); defer { unlock() }` critical section, so including it
/// would produce false positives on the most ordinary pattern in Swift. The distinction that
/// justifies the exclusion: these primitives wait for an **event that may never occur**, while a
/// lock waits for **mutual exclusion** bounded by a critical section in the same program.
/// Lock-ordering deadlock is a real hazard requiring lock-order analysis, and must not be
/// smuggled into a rule that cannot perform it.
struct BlockingPrimitive: Sendable {
    /// The receiver type whose method blocks without a bound.
    let typeName: String
    /// The method that blocks when called with no arguments.
    let method: String
    /// The bounded overload the caller should have used instead.
    let boundedForm: String

    /// Every primitive this checker knows about. The table *is* the coverage claim, which is why
    /// its size is printed on every run.
    static let all: [BlockingPrimitive] = [
        BlockingPrimitive(typeName: "DispatchSemaphore", method: "wait", boundedForm: "wait(timeout:)"),
        BlockingPrimitive(typeName: "DispatchGroup", method: "wait", boundedForm: "wait(timeout:)"),
        BlockingPrimitive(typeName: "NSCondition", method: "wait", boundedForm: "wait(until:)")
    ]
}

/// What one file's scan found, and what it could not see.
struct LivenessScan: Sendable {
    /// Findings, one per unbounded call.
    let diagnostics: [Diagnostic]
    /// Calls whose receiver resolved to a known primitive.
    let examined: Int
    /// Calls named like a primitive whose receiver type could not be resolved syntactically.
    let skipped: Int

    /// The scope of the claim, printed pass or fail.
    ///
    /// A previous auditor's silence was read as "subprocesses cannot hang" when it meant "nobody
    /// wrote one syntactic shape". Stating the skipped count makes a green run report its own
    /// blind spot rather than conceal it.
    var coverageLine: String {
        "liveness examined \(examined) blocking wait\(examined == 1 ? "" : "s")"
            + " against \(BlockingPrimitive.all.count) known primitives"
            + (skipped > 0 ? " · \(skipped) skipped (receiver type unresolved)" : "")
    }
}

/// Finds calls to blocking primitives that declined an available deadline.
///
/// ## Why the receiver type is resolved syntactically
///
/// SwiftSyntax carries no type information, so `semaphore.wait()` and `queue.wait()` are the same
/// tree. Rather than depend on the index — which would put staleness back into the one tier whose
/// value is being decidable — this binds names to types from declarations in the same file:
/// initializer calls, type annotations, and parameter types.
///
/// When a receiver cannot be resolved, the call is **skipped, not reported**. Under-reporting is
/// the correct direction to fail: the tier's worth is that a finding is never arguable, and every
/// unresolved receiver is counted into the coverage line so the gap is visible.
final class LivenessVisitor: SyntaxVisitor {
    private let fileName: String
    private let converter: SourceLocationConverter
    private var bindings: [String: String] = [:]
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var examined = 0
    private(set) var skipped = 0

    init(fileName: String, converter: SourceLocationConverter) {
        self.fileName = fileName
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    /// Binds `let s = DispatchSemaphore(...)` and `let s: DispatchSemaphore`.
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            if let annotated = binding.typeAnnotation?.type.trimmedDescription {
                bindings[name] = annotated
            } else if let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
                      let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text {
                bindings[name] = callee
            }
        }
        return .visitChildren
    }

    /// Binds `func f(_ c: NSCondition)`.
    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        let name = node.secondName?.text ?? node.firstName.text
        bindings[name] = node.type.trimmedDescription
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return .visitChildren
        }
        let method = member.declName.baseName.text
        guard BlockingPrimitive.all.contains(where: { $0.method == method }) else {
            return .visitChildren
        }
        guard let receiver = receiverName(of: member.base) else { return .visitChildren }

        guard let type = bindings[receiver] else {
            // A wait-shaped call on a receiver this file does not declare. Counted, never
            // guessed at — see the type-resolution note above.
            skipped += 1
            return .visitChildren
        }
        guard let primitive = BlockingPrimitive.all.first(
            where: { $0.typeName == type && $0.method == method }) else {
            return .visitChildren
        }

        examined += 1
        // The deadline is the argument. Taking it is exactly what makes this call bounded, so a
        // call with any argument is the corrected form and not a finding.
        guard node.arguments.isEmpty else { return .visitChildren }

        let location = node.startLocation(converter: converter)
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "\(type).\(method)() waits with no deadline — "
                + "\(primitive.boundedForm) is available and was not used.",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "liveness.unbounded-wait",
            suggestedFix: "Use \(primitive.boundedForm) and decide what happens when it fires."))
        return .visitChildren
    }

    /// The receiver's identifier, for `s.wait()` and `self.s.wait()`.
    private func receiverName(of base: ExprSyntax?) -> String? {
        if let ref = base?.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let member = base?.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }
}
