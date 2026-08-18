import Foundation
import QualityGateCore
import SwiftSyntax

/// A blocking primitive with **no bounded overload anywhere in its API**.
///
/// These differ in kind from the ones `liveness` reports. There, the vendor offered a deadline
/// and the call site declined it, so the repair is local and the finding is unarguable. Here no
/// deadline exists to take: `readDataToEndOfFile()` returns at EOF or never, and EOF arrives only
/// when every write end closes — including copies held by grandchildren the code cannot see.
///
/// Such a call can only be bounded from outside, by a watchdog or a deadline on another thread,
/// which is why this checker does not try to decide whether any particular one is bounded.
struct UnboundedPrimitive: Sendable {
    /// The method name as written at the call site.
    let method: String
    /// Why it cannot be bounded in place, quoted back to the reader in the diagnostic.
    let reason: String

    static let all: [UnboundedPrimitive] = [
        UnboundedPrimitive(
            method: "readDataToEndOfFile",
            reason: "returns at EOF or never, and EOF waits on every inherited write end"),
        UnboundedPrimitive(
            method: "waitUntilExit",
            reason: "returns when the child exits or never"),
        UnboundedPrimitive(
            method: "availableData",
            reason: "blocks until the pipe has something or the writer closes")
    ]
}

/// What one file's scan found, and the size of the claim behind it.
struct BoundedIOScan: Sendable {
    let diagnostics: [Diagnostic]
    let sitesExamined: Int
    /// Sites carrying a reasoned `// Unbounded:` marker.
    let acknowledged: Int

    /// The kernel this run measured against, named so a foreign repository's note is true.
    let kernelName: String

    var coverageLine: String {
        "bounded-io examined \(sitesExamined) subprocess site\(sitesExamined == 1 ? "" : "s")"
            + " against \(UnboundedPrimitive.all.count) unbounded primitives"
            + "; the kernel is \(kernelName)"
            + (acknowledged > 0 ? " · \(acknowledged) acknowledged out of kernel" : "")
    }
}

/// Reports unbounded primitives called outside the audited kernel.
///
/// ## The trade this makes
///
/// Deciding whether a wait is genuinely bounded would require modelling subprocess lifetime,
/// process groups, signal delivery, whether `terminate()` reaches descendants, descriptor
/// inheritance, thread scheduling, cancellation, and whether a timeout handler is reachable
/// *after* the wait — let alone whether it interrupts the wait or merely records that it fired.
/// No syntactic pass discharges that list, and one that appeared to would be worse than none: it
/// would issue clean verdicts about hangs.
///
/// So the question changes from one that cannot be answered to one that can. Not *"is this
/// bounded?"* but *"is this called outside the kernel?"* — decidable, local, no call graph. The
/// same trade `unsafe` blocks make: confine what cannot be proven, and audit the confinement.
///
/// ## Why containment is worth more than the checking
///
/// The deadline fix that motivated this landed on **one of nine sites**, because there was no
/// kernel for a correct fix to propagate from. Containment does not make the kernel correct — the
/// kernel was wrong for three months. It makes the kernel *the only place that has to be*, and
/// small enough to carry a regression corpus of every hang ever found.
final class BoundedIOVisitor: SyntaxVisitor {
    private let fileName: String
    private let converter: SourceLocationConverter
    private let sourceLines: [String]
    private let isKernel: Bool
    /// The kernel's name, for messages that must not cite a symbol the reader cannot import.
    private let kernelName: String
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var sitesExamined = 0
    private(set) var acknowledged = 0

    init(fileName: String, converter: SourceLocationConverter, sourceLines: [String], isKernel: Bool, kernelName: String) {
        self.fileName = fileName
        self.converter = converter
        self.sourceLines = sourceLines
        self.isKernel = isKernel
        self.kernelName = kernelName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // `Process()` / `NSTask()` construction. Absorbed from `security.command-injection`, whose
        // mechanism was `callee == "Process"` — a containment check wearing an injection rule's
        // name. It was switched off in config by reasoning that was correct about injection and
        // blind to the second job the rule was doing, which is how nine unbounded sites stayed
        // invisible for months. Split apart here so the injection rule can be rewritten to
        // actually inspect its arguments and earn its name.
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "Process" || ref.baseName.text == "NSTask" {
            record(node: Syntax(node),
                   ruleId: "bounded-io.process-construction",
                   message: "\(ref.baseName.text)() constructed outside the kernel — "
                       + "spawn through \(kernelName), which bounds the run and drains its pipes.",
                   fix: "Use \(kernelName).run(_:arguments:timeout:)")
            return .visitChildren
        }

        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           let primitive = UnboundedPrimitive.all.first(where: { $0.method == member.declName.baseName.text }) {
            record(node: Syntax(node),
                   ruleId: "bounded-io.outside-kernel",
                   message: "\(primitive.method)() outside the kernel — \(primitive.reason). "
                       + "It cannot be bounded here; route the spawn through \(kernelName).",
                   fix: "Use \(kernelName).run(_:arguments:timeout:)")
        }
        return .visitChildren
    }

    /// `availableData` is a property, so it arrives as a member access rather than a call.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.declName.baseName.text == "availableData",
              let primitive = UnboundedPrimitive.all.first(where: { $0.method == "availableData" })
        else { return .visitChildren }
        record(node: Syntax(node),
               ruleId: "bounded-io.outside-kernel",
               message: "availableData outside the kernel — \(primitive.reason). "
                   + "Route the spawn through \(kernelName).",
               fix: "Use \(kernelName).run(_:arguments:timeout:)")
        return .visitChildren
    }

    private func record(node: Syntax, ruleId: String, message: String, fix: String) {
        sitesExamined += 1
        // The kernel is where these primitives are supposed to live. Its correctness is carried by
        // `ProcessRunnerDeadlineTests` — a corpus of every hang variant yet found — not by this
        // checker, which never claims the kernel is bounded, only that nothing else pretends to be.
        guard !isKernel else { return }

        let location = node.startLocation(converter: converter)

        // An acknowledged site is counted into the coverage note rather than emitted as its own
        // warning, following `TrapPolicy`'s `aggregate` mode. The reason is not leniency: this
        // project's rule is that zero warnings means zero, so per-site warnings for eighteen
        // *deliberate, documented* decisions would keep the gate permanently red and the only
        // ways out would be deleting the rule or ignoring the colour. Aggregating keeps the
        // number in front of the reader on every run — which is the point — without making a
        // recorded decision indistinguishable from an unfixed defect.
        guard !acknowledgement(above: location.line) else {
            acknowledged += 1
            return
        }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: message,
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: ruleId,
            suggestedFix: fix))
    }

    /// Whether line `line - 1` carries `// Unbounded:` **with a stated reason**.
    ///
    /// A bare marker does not count, and that is the point rather than strictness for its own
    /// sake. If the justification cannot be written truthfully, the inability to write it *is*
    /// the finding: `PluginRunner` arms a watchdog that terminates the child, which reads as
    /// bounding the run and does not bound the read, because a grandchild holding the inherited
    /// write end keeps the pipe open. No honest sentence describes that as bounded.
    private func acknowledgement(above line: Int) -> Bool {
        let index = line - 2   // 1-based line numbers, and we want the line above.
        guard index >= 0, index < sourceLines.count else { return false }
        let text = sourceLines[index].trimmingCharacters(in: .whitespaces)
        guard let range = text.range(of: "// Unbounded:") else { return false }
        return !text[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
    }
}
