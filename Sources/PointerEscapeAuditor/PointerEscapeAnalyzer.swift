import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Known function name sets

/// Functions that introduce a pointer borrow scope.
let withUnsafeFunctionNames: Set<String> = [
    "withUnsafePointer",
    "withUnsafeMutablePointer",
    "withUnsafeBytes",
    "withUnsafeMutableBytes",
    "withUnsafeBufferPointer",
    "withUnsafeMutableBufferPointer",
    "withCString",
    "withMemoryRebound",
]

/// Function names whose closure argument is structurally escaping in our model.
let escapingClosureCallees: Set<String> = ["async", "asyncAfter", "Task"]

/// Member names that read a value from a pointer (not the pointer itself).
let pointerValueAccessors: Set<String> = [
    "pointee", "first", "last", "count", "isEmpty",
    "indices", "startIndex", "endIndex", "underestimatedCount",
]

/// Method names that consume a buffer pointer to produce a value.
let pointerValueMethods: Set<String> = [
    "reduce", "map", "filter", "forEach", "compactMap", "flatMap",
    "reversed", "sorted", "contains", "allSatisfy", "min", "max",
]

// MARK: - Top-level visitor

/// Top-level visitor that finds `withUnsafe*` call sites and recursively
/// analyzes them. Also handles the `unmanaged-retain-leak` rule which is
/// type-level rather than per-with-block.
final class PointerEscapeVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let allowedEscapeFunctions: Set<String>
    let sourceText: String

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    init(
        fileName: String,
        converter: SourceLocationConverter,
        allowedEscapeFunctions: Set<String>,
        sourceText: String
    ) {
        self.fileName = fileName
        self.converter = converter
        self.allowedEscapeFunctions = allowedEscapeFunctions
        self.sourceText = sourceText
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: With-block discovery

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if isWithUnsafeCall(node), let closure = node.trailingClosure {
            analyzeWithBlock(closure: closure, parentTracked: [])
            return .skipChildren
        }
        return .visitChildren
    }

    // MARK: Type-level rule: unmanaged retain leak

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnmanagedRetainLeak(memberBlock: node.memberBlock)
        return .visitChildren
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        checkUnmanagedRetainLeak(memberBlock: node.memberBlock)
        return .visitChildren
    }

    private func checkUnmanagedRetainLeak(memberBlock: MemberBlockSyntax) {
        var hasPassRetained = false
        var passRetainedLine = 0
        var hasReleaseInDeinit = false

        final class Walker: SyntaxVisitor {
            var foundPassRetained: Bool = false
            var passRetainedLine: Int = 0
            var foundReleaseInDeinit: Bool = false
            let converter: SourceLocationConverter
            init(converter: SourceLocationConverter) {
                self.converter = converter
                super.init(viewMode: .sourceAccurate)
            }
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                let text = node.calledExpression.trimmedDescription
                if text.contains("Unmanaged.passRetained") {
                    foundPassRetained = true
                    passRetainedLine = node.startLocation(converter: converter).line
                }
                return .visitChildren
            }
            override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
                let bodyText = node.body?.trimmedDescription ?? ""
                if bodyText.contains(".release()") {
                    foundReleaseInDeinit = true
                }
                return .skipChildren
            }
        }
        let walker = Walker(converter: converter)
        walker.walk(memberBlock)
        hasPassRetained = walker.foundPassRetained
        passRetainedLine = walker.passRetainedLine
        hasReleaseInDeinit = walker.foundReleaseInDeinit

        if hasPassRetained && !hasReleaseInDeinit {
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "Unmanaged.passRetained creates a +1 retain that is never balanced by a release()",
                file: fileName,
                line: passRetainedLine,
                column: 1,
                ruleId: "pointer-escape.unmanaged-retain-leak",
                suggestedFix: "Add a matching .release() call (typically in deinit)."
            ))
        }
    }

    // MARK: With-block analyzer

    /// Recursively analyzes a `withUnsafe*` closure body for pointer escapes.
    /// `parentTracked` carries pointer names from enclosing with-blocks (for
    /// nested-scope tests).
    fileprivate func analyzeWithBlock(closure: ClosureExprSyntax, parentTracked: Set<String>) {
        let bound = extractClosureBoundNames(closure)
        if bound.isEmpty && parentTracked.isEmpty {
            // Nothing to track (e.g. `{ _ in ... }` and no parent context).
            // Still need to scan for nested with-blocks.
            walkForNestedWithBlocks(in: closure.statements, parentTracked: parentTracked)
            return
        }

        var tracked = parentTracked.union(bound)
        var locals: Set<String> = []

        // Walk all body items.
        walkBodyItems(closure.statements, tracked: &tracked, locals: &locals)

        // Implicit-return handling: if the last item in the closure body is a
        // bare expression (no `return` keyword), treat it as a returned value.
        if let lastItem = closure.statements.last,
           let expr = lastItem.item.as(ExprSyntax.self) {
            handleReturn(expression: expr, tracked: tracked)
        }
    }

    private func walkForNestedWithBlocks(in items: CodeBlockItemListSyntax, parentTracked: Set<String>) {
        // For closures with no bound names, still recurse into nested with-blocks.
        let collector = NestedWithBlockCollector(viewMode: .sourceAccurate)
        collector.walk(items)
        for inner in collector.calls {
            if let innerClosure = inner.trailingClosure {
                analyzeWithBlock(closure: innerClosure, parentTracked: parentTracked)
            }
        }
    }

    private func walkBodyItems(_ items: CodeBlockItemListSyntax, tracked: inout Set<String>, locals: inout Set<String>) {
        for item in items {
            processItem(item, tracked: &tracked, locals: &locals)
        }
    }

    private func processItem(_ item: CodeBlockItemSyntax, tracked: inout Set<String>, locals: inout Set<String>) {
        let element = item.item

        // Variable declarations: handle alias / shadow tracking AND examine
        // closure RHS bindings (which are NOT escapes — they're local).
        if let varDecl = element.as(DeclSyntax.self)?.as(VariableDeclSyntax.self) {
            handleVariableDecl(varDecl, tracked: &tracked, locals: &locals)
            return
        }

        // Statements
        if let stmt = element.as(StmtSyntax.self) {
            processStatement(stmt, tracked: &tracked, locals: &locals)
            return
        }

        // Expressions
        if let expr = element.as(ExprSyntax.self) {
            processTopLevelExpression(expr, tracked: &tracked, locals: &locals)
            return
        }
    }

    private func processStatement(_ stmt: StmtSyntax, tracked: inout Set<String>, locals: inout Set<String>) {
        if let returnStmt = stmt.as(ReturnStmtSyntax.self) {
            if let expr = returnStmt.expression {
                handleReturn(expression: expr, tracked: tracked)
            }
            return
        }
        if let ifStmt = stmt.as(IfExprSyntax.self) {
            // if statements are actually expressions in Swift; handled below
            _ = ifStmt
        }
        if let guardStmt = stmt.as(GuardStmtSyntax.self) {
            walkBodyItems(guardStmt.body.statements, tracked: &tracked, locals: &locals)
            return
        }
        if let forStmt = stmt.as(ForStmtSyntax.self) {
            walkBodyItems(forStmt.body.statements, tracked: &tracked, locals: &locals)
            return
        }
        if let whileStmt = stmt.as(WhileStmtSyntax.self) {
            walkBodyItems(whileStmt.body.statements, tracked: &tracked, locals: &locals)
            return
        }
        if let doStmt = stmt.as(DoStmtSyntax.self) {
            walkBodyItems(doStmt.body.statements, tracked: &tracked, locals: &locals)
            return
        }
        if let deferStmt = stmt.as(DeferStmtSyntax.self) {
            walkBodyItems(deferStmt.body.statements, tracked: &tracked, locals: &locals)
            return
        }
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
            processTopLevelExpression(exprStmt.expression, tracked: &tracked, locals: &locals)
            return
        }
    }

    private func processTopLevelExpression(_ expr: ExprSyntax, tracked: inout Set<String>, locals: inout Set<String>) {
        // If expression: walk both branches
        if let ifExpr = expr.as(IfExprSyntax.self) {
            walkBodyItems(ifExpr.body.statements, tracked: &tracked, locals: &locals)
            if let elseBody = ifExpr.elseBody {
                switch elseBody {
                case .codeBlock(let block):
                    walkBodyItems(block.statements, tracked: &tracked, locals: &locals)
                case .ifExpr(let nested):
                    var t = tracked
                    var l = locals
                    processTopLevelExpression(ExprSyntax(nested), tracked: &t, locals: &l)
                }
            }
            return
        }

        // Switch expression
        if let switchExpr = expr.as(SwitchExprSyntax.self) {
            for caseItem in switchExpr.cases {
                if let switchCase = caseItem.as(SwitchCaseSyntax.self) {
                    walkBodyItems(switchCase.statements, tracked: &tracked, locals: &locals)
                }
            }
            return
        }

        // Sequence expression (for assignments)
        if let sequence = expr.as(SequenceExprSyntax.self) {
            handleSequenceExpression(sequence, tracked: tracked, locals: locals)
            return
        }

        // Function call
        if let call = expr.as(FunctionCallExprSyntax.self) {
            handleFunctionCall(call, tracked: &tracked, locals: &locals)
            return
        }
    }

    private func handleVariableDecl(_ varDecl: VariableDeclSyntax, tracked: inout Set<String>, locals: inout Set<String>) {
        for binding in varDecl.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = pattern.identifier.text
            locals.insert(name)
            guard let initializer = binding.initializer else { continue }
            let rhs = initializer.value

            // Local closure binding (`let local = { ... }`) — never an escape.
            if rhs.is(ClosureExprSyntax.self) {
                continue
            }

            // Alias of a tracked pointer?
            if isPointerExpression(rhs, tracked: tracked) {
                tracked.insert(name)
                continue
            }

            // Shadow of a previously tracked name?
            if tracked.contains(name) {
                tracked.remove(name)
            }
        }
    }

    // MARK: Escape sinks

    private func handleReturn(expression: ExprSyntax, tracked: Set<String>) {
        // 0. If the implicit-return expression is itself a call to an
        //    allowlisted function, the user has opted in to letting that
        //    function receive the borrowed pointer.
        if let call = expression.as(FunctionCallExprSyntax.self), isAllowlistedCall(call) {
            let functionName = allowlistedFunctionName(call) ?? "unknown"
            overrides.append(DiagnosticOverride(
                ruleId: "pointer-escape",
                justification: "Allowed by configuration: \(functionName)",
                filePath: fileName,
                lineNumber: line(of: call)
            ))
            return
        }
        // 1. Closure literal capturing a tracked pointer → stored-closure escape.
        if let closure = expression.as(ClosureExprSyntax.self),
           closureCapturesAnyTrackedName(closure, tracked: tracked) {
            emitStoredClosure(at: expression)
            return
        }
        // 2. OpaquePointer wrapping a tracked pointer → opaque-roundtrip warning.
        if let call = expression.as(FunctionCallExprSyntax.self),
           let ident = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ident.baseName.text == "OpaquePointer",
           call.arguments.contains(where: { expressionContainsTrackedPointer($0.expression, tracked: tracked) }) {
            emitOpaqueRoundtrip(at: expression)
            return
        }
        // 3. Generic pointer escape via return.
        if expressionContainsTrackedPointer(expression, tracked: tracked) {
            emitReturnFromWithBlock(at: expression)
        }
    }

    private func handleSequenceExpression(_ seq: SequenceExprSyntax, tracked: Set<String>, locals: Set<String>) {
        let elements = Array(seq.elements)
        for (idx, element) in elements.enumerated() {
            if element.is(AssignmentExprSyntax.self), idx > 0, idx + 1 < elements.count {
                let lhs = elements[idx - 1]
                let rhs = ExprSyntax(SequenceExprSyntax(elements: ExprListSyntax(Array(elements[(idx + 1)...]))))
                let actualRHS: ExprSyntax = (idx + 1 == elements.count - 1) ? elements[idx + 1] : rhs
                handleAssignment(lhs: lhs, rhs: actualRHS, tracked: tracked, locals: locals)
            }
        }
    }

    private func handleAssignment(lhs: ExprSyntax, rhs: ExprSyntax, tracked: Set<String>, locals: Set<String>) {
        // RHS analysis
        let rhsIsClosureCapturingTracked: Bool = {
            if let closure = rhs.as(ClosureExprSyntax.self) {
                return closureCapturesAnyTrackedName(closure, tracked: tracked)
            }
            return false
        }()
        let rhsContainsTrackedPointer = expressionContainsTrackedPointer(rhs, tracked: tracked)

        // LHS classification
        let lhsKind = classifyLHS(lhs, locals: locals)

        switch lhsKind {
        case .selfMember:
            if rhsIsClosureCapturingTracked {
                emitStoredClosure(at: lhs)
            } else if rhsContainsTrackedPointer {
                emitStoredInProperty(at: lhs)
            }
        case .outerVar, .typeStaticMember:
            if rhsIsClosureCapturingTracked {
                emitStoredClosure(at: lhs)
            } else if rhsContainsTrackedPointer {
                emitAssignedToOuterCapture(at: lhs)
            }
        case .local, .unknown:
            break
        }
    }

    private enum LHSKind {
        case selfMember            // self.x
        case outerVar              // bare identifier not in locals
        case typeStaticMember      // Type.x where Type is uppercase
        case local                 // bare identifier in locals
        case unknown
    }

    private func classifyLHS(_ expr: ExprSyntax, locals: Set<String>) -> LHSKind {
        if let ident = expr.as(DeclReferenceExprSyntax.self) {
            return locals.contains(ident.baseName.text) ? .local : .outerVar
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            if let base = member.base {
                if base.trimmedDescription == "self" {
                    return .selfMember
                }
                if let baseIdent = base.as(DeclReferenceExprSyntax.self),
                   baseIdent.baseName.text.first?.isUppercase == true {
                    return .typeStaticMember
                }
            }
        }
        // self[i] or other subscript-style LHS not modeled
        return .unknown
    }

    // MARK: Function-call rules

    private func handleFunctionCall(_ call: FunctionCallExprSyntax, tracked: inout Set<String>, locals: inout Set<String>) {
        // Nested with-block? Recurse.
        if isWithUnsafeCall(call), let closure = call.trailingClosure {
            analyzeWithBlock(closure: closure, parentTracked: tracked)
            return
        }

        // Allowlisted function — fully suppress checks.
        if isAllowlistedCall(call) {
            let functionName = allowlistedFunctionName(call) ?? "unknown"
            overrides.append(DiagnosticOverride(
                ruleId: "pointer-escape",
                justification: "Allowed by configuration: \(functionName)",
                filePath: fileName,
                lineNumber: line(of: call)
            ))
            return
        }

        // Compute called method name once for the rest of the function.
        let calledMemberName: String? = call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text

        // Detect collection mutation: outer.append(ptr), outer.insert(ptr, at: 0)
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           let receiver = member.base,
           receiver.is(DeclReferenceExprSyntax.self) {
            let methodName = member.declName.baseName.text
            if methodName == "append" || methodName == "insert" {
                if call.arguments.contains(where: { expressionContainsTrackedPointer($0.expression, tracked: tracked) }) {
                    emitAppendedToOuterCollection(at: call)
                    return
                }
            }
        }

        // Inout pattern: call has both an inout-bound ampersand AND a tracked pointer.
        let hasInoutOuter = call.arguments.contains { arg in
            if let inout_ = arg.expression.as(InOutExprSyntax.self) {
                _ = inout_
                return true
            }
            return false
        }
        let hasTrackedArg = call.arguments.contains { expressionContainsTrackedPointer($0.expression, tracked: tracked) }
        if hasInoutOuter && hasTrackedArg {
            emitPassedAsInout(at: call)
            return
        }

        // Escaping closure capture (warning tier)
        if isEscapingClosureCallSite(call), let closure = call.trailingClosure {
            if closureCapturesAnyTrackedName(closure, tracked: tracked) {
                emitCapturedByEscapingClosure(at: call)
            }
        }

        // Fallback: any non-allowlisted function call that receives a tracked
        // pointer as a positional argument is a potential escape. We don't know
        // the function's contract, so we treat it conservatively.
        let alreadyHandled = (calledMemberName == "append" || calledMemberName == "insert")
        if !alreadyHandled && !hasInoutOuter && hasTrackedArg {
            emitPassedAsInout(at: call)
        }

        // Walk into nested expressions for further calls / nested with-blocks
        for arg in call.arguments {
            if let nested = arg.expression.as(FunctionCallExprSyntax.self) {
                handleFunctionCall(nested, tracked: &tracked, locals: &locals)
            }
        }
        // Also walk trailing closure body for non-escaping calls (forEach etc.)
        if let trailing = call.trailingClosure {
            // Track-and-walk the closure body. forEach/sync etc. are non-escaping.
            var subTracked = tracked
            var subLocals = locals
            walkBodyItems(trailing.statements, tracked: &subTracked, locals: &subLocals)
        }
    }

    private func isAllowlistedCall(_ call: FunctionCallExprSyntax) -> Bool {
        if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return allowedEscapeFunctions.contains(ident.baseName.text)
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return allowedEscapeFunctions.contains(member.declName.baseName.text)
        }
        return false
    }

    private func allowlistedFunctionName(_ call: FunctionCallExprSyntax) -> String? {
        if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self),
           allowedEscapeFunctions.contains(ident.baseName.text) {
            return ident.baseName.text
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           allowedEscapeFunctions.contains(member.declName.baseName.text) {
            return member.declName.baseName.text
        }
        return nil
    }

    private func isEscapingClosureCallSite(_ call: FunctionCallExprSyntax) -> Bool {
        if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return escapingClosureCallees.contains(ident.baseName.text)
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return escapingClosureCallees.contains(member.declName.baseName.text)
        }
        return false
    }

    // MARK: Diagnostic emitters

    private func line(of node: some SyntaxProtocol) -> Int {
        node.startLocation(converter: converter).line
    }

    private func emitReturnFromWithBlock(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer escapes the with-block; the underlying memory is invalid after the closure returns",
            file: fileName,
            line: line(of: node),
            column: 1,
            ruleId: "pointer-escape.return-from-with-block",
            suggestedFix: "Return the dereferenced value (e.g. ptr.pointee) instead of the pointer itself."
        ))
    }
    private func emitAssignedToOuterCapture(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer escapes by assignment to a variable outside the with-block",
            file: fileName,
            line: line(of: node),
            column: 1,
            ruleId: "pointer-escape.assigned-to-outer-capture",
            suggestedFix: "Copy the pointee value instead of the pointer."
        ))
    }
    private func emitStoredInProperty(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer escapes by being stored in a property",
            file: fileName,
            line: line(of: node),
            column: 1,
            ruleId: "pointer-escape.stored-in-property",
            suggestedFix: "Store the pointee value or a Sendable copy instead."
        ))
    }
    private func emitAppendedToOuterCollection(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer escapes by being appended/inserted into a collection outside the with-block",
            file: fileName,
            line: line(of: node),
            column: 1,
            ruleId: "pointer-escape.appended-to-outer-collection",
            suggestedFix: "Append the pointee value, not the pointer."
        ))
    }
    private func emitPassedAsInout(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer escapes by being passed alongside an inout outer variable",
            file: fileName,
            line: line(of: node),
            column: 1,
            ruleId: "pointer-escape.passed-as-inout",
            suggestedFix: "Avoid passing the pointer to a function that may store it via inout."
        ))
    }
    private func emitStoredClosure(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "closure literal captures a pointer that becomes invalid after the with-block",
            file: fileName,
            line: line(of: node),
            column: 1,
            ruleId: "pointer-escape.stored-closure-captures-pointer",
            suggestedFix: "Capture the pointee value (or copy it into a Sendable wrapper) before storing the closure."
        ))
    }
    private func emitCapturedByEscapingClosure(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "pointer captured by an escaping closure may be used after the with-block ends",
            file: fileName,
            line: line(of: node),
            column: 1,
            ruleId: "pointer-escape.captured-by-escaping-closure",
            suggestedFix: "Use the synchronous variant or copy the pointee value before capturing."
        ))
    }
    private func emitOpaqueRoundtrip(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "pointer round-trips through OpaquePointer; the underlying memory is invalid after the with-block",
            file: fileName,
            line: line(of: node),
            column: 1,
            ruleId: "pointer-escape.opaque-roundtrip",
            suggestedFix: "Keep both the typed and opaque forms inside the same with-block."
        ))
    }
}

// MARK: - Helper visitor: collect nested with-block calls

private final class NestedWithBlockCollector: SyntaxVisitor {
    var calls: [FunctionCallExprSyntax] = []
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if isWithUnsafeCall(node) {
            calls.append(node)
            return .skipChildren
        }
        return .visitChildren
    }
}

// MARK: - Pointer / closure analysis helpers

func isWithUnsafeCall(_ call: FunctionCallExprSyntax) -> Bool {
    if let ident = call.calledExpression.as(DeclReferenceExprSyntax.self),
       withUnsafeFunctionNames.contains(ident.baseName.text) {
        return true
    }
    if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
       withUnsafeFunctionNames.contains(member.declName.baseName.text) {
        return true
    }
    return false
}

/// Extracts the bound parameter names of a closure. `_` parameters are
/// excluded. If the closure has no signature, returns the implicit `$0`.
func extractClosureBoundNames(_ closure: ClosureExprSyntax) -> Set<String> {
    if let signature = closure.signature, let paramClause = signature.parameterClause {
        var names: Set<String> = []
        switch paramClause {
        case .simpleInput(let list):
            for param in list {
                let name = param.name.text
                if name != "_" { names.insert(name) }
            }
        case .parameterClause(let clause):
            for param in clause.parameters {
                let firstName = param.firstName.text
                if firstName != "_" { names.insert(firstName) }
            }
        }
        return names
    }
    return ["$0"]
}

/// True if the expression evaluates to (or wraps) a tracked pointer. Skips
/// `.pointee` / value-extracting member accesses and value-method receivers.
func isPointerExpression(_ expr: ExprSyntax, tracked: Set<String>) -> Bool {
    return expressionContainsTrackedPointer(expr, tracked: tracked)
}

/// Walks an expression looking for tracked pointer references. Skips
/// subtrees rooted at `.pointee`, `.first`, etc., and at value-producing
/// methods like `.reduce`, `.map` (the receiver of those methods is treated
/// as opaque, but their arguments are still walked).
func expressionContainsTrackedPointer(_ expr: ExprSyntax, tracked: Set<String>) -> Bool {
    final class Walker: SyntaxVisitor {
        let tracked: Set<String>
        var found = false
        init(tracked: Set<String>) {
            self.tracked = tracked
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            if pointerValueAccessors.contains(node.declName.baseName.text) {
                return .skipChildren
            }
            return .visitChildren
        }
        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
               pointerValueMethods.contains(member.declName.baseName.text) {
                // Walk only arguments, not the receiver chain.
                for arg in node.arguments {
                    walk(arg.expression)
                }
                return .skipChildren
            }
            return .visitChildren
        }
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            // Don't descend into closure bodies — those are escapes via a
            // separate rule path, not a value-flow escape of the outer expr.
            return .skipChildren
        }
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if tracked.contains(node.baseName.text) {
                found = true
            }
            return .skipChildren
        }
    }
    let walker = Walker(tracked: tracked)
    walker.walk(expr)
    return walker.found
}

/// True if a closure literal references any tracked name in its body, even
/// indirectly through `.pointee` or value methods. Used for closure-capture
/// rules where the act of capturing is the escape.
func closureCapturesAnyTrackedName(_ closure: ClosureExprSyntax, tracked: Set<String>) -> Bool {
    final class Walker: SyntaxVisitor {
        let tracked: Set<String>
        var found = false
        init(tracked: Set<String>) {
            self.tracked = tracked
            super.init(viewMode: .sourceAccurate)
        }
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if tracked.contains(node.baseName.text) {
                found = true
            }
            return .skipChildren
        }
    }
    let walker = Walker(tracked: tracked)
    walker.walk(closure.statements)
    return walker.found
}
