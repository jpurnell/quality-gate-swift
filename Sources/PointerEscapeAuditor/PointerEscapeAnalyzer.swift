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

/// Argument labels that hand a pointer over rather than copying from it.
///
/// `Data(bytesNoCopy:count:deallocator:)` is the one that matters in practice: it looks like
/// every other `Data` initializer and is the only one that keeps pointing at the block's memory
/// after the block returns.
let pointerRetainingArgumentLabels: Set<String> = [
    "bytesNoCopy", "bytesNoCopyOf", "start",
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
    private(set) var complianceRecords: [ComplianceRecord] = []

    /// The with-blocks enclosing the code currently being analysed, outermost first.
    ///
    /// `pointer-escape.assigned-to-outer-member` needs to know *which* block lent a pointer,
    /// because the pointer is valid until that block — not the innermost one — returns.
    private var withScopes: [WithScope] = []
    /// The with-blocks enclosing the code currently being analysed, outermost first.
    ///
    /// `pointer-escape.assigned-to-outer-member` needs to know *which* block lent a pointer,
    /// because the pointer is valid until that block — not the innermost one — returns.

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
                filePath: fileName,
                lineNumber: passRetainedLine,
                columnNumber: 1,
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
        withScopes.append(WithScope(closure: closure, bound: bound))
        defer { withScopes.removeLast() }
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
        guard !items.isEmpty else { return }
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
        // IfExprSyntax is an expression, not a statement — handled in
        // walkExpression rather than here.
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
        if let repeatStmt = stmt.as(RepeatStmtSyntax.self) {
            walkBodyItems(repeatStmt.body.statements, tracked: &tracked, locals: &locals)
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
        // `try buf.withUnsafeBytes { … }` opens a nested with-block exactly as the bare call
        // does. Only the with-block is unwrapped here: other `try` calls keep their existing
        // treatment, which `BorrowedArgumentTests` pins.
        if let call = unwrappingEffects(expr).as(FunctionCallExprSyntax.self),
           !expr.is(FunctionCallExprSyntax.self), isWithUnsafeCall(call), let closure = call.trailingClosure {
            analyzeWithBlock(closure: closure, parentTracked: tracked)
            return
        }

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

            // `let n = buf.withUnsafeBytes { … }` opens a nested with-block, which is analysed
            // like one written as a statement.
            if let call = unwrappingEffects(rhs).as(FunctionCallExprSyntax.self),
               isWithUnsafeCall(call), let closure = call.trailingClosure {
                analyzeWithBlock(closure: closure, parentTracked: tracked)
            }

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
        // An assignment is the closure's last statement, not its result: its value is `()`.
        // Without this, `{ p in stream.next_in = p.baseAddress }` reported the *assignment's*
        // escape a second time, as a return the closure never makes.
        if let sequence = expression.as(SequenceExprSyntax.self),
           sequence.elements.contains(where: { $0.is(AssignmentExprSyntax.self) }) {
            return
        }
        // 0. If the implicit-return expression is itself a call to an
        //    allowlisted function, the user has opted in to letting that
        //    function receive the borrowed pointer.
        if let call = expression.as(FunctionCallExprSyntax.self), isAllowlistedCall(call) {
            let functionName = allowlistedFunctionName(call) ?? "unknown"
            complianceRecords.append(ComplianceRecord(
                ruleId: "pointer-escape",
                annotation: "Allowed by configuration: \(functionName)",
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
        //
        // `isPointerExpression`, not `expressionContainsTrackedPointer`: what matters is whether
        // the value *leaving* the block is a pointer, not whether one is mentioned on the way to
        // producing it. The other call sites below keep the broader test, because there the
        // pointer being an argument is exactly the escape — it is what gets stored.
        if isPointerExpression(expression, tracked: tracked) {
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
        case .outerMember(let root, let path):
            let storesClosure = rhsIsClosureCapturingTracked
            guard storesClosure || isPointerExpression(rhs, tracked: tracked) else { return }
            guard storedPointerOutlivesBlock(rhs: rhs, tracked: tracked, root: root, path: path) else { return }
            if storesClosure {
                emitStoredClosure(at: lhs)
            } else {
                emitAssignedToOuterMember(at: lhs, root: root)
            }
        case .local, .unknown:
            break
        }
    }

    private enum LHSKind {
        case selfMember            // self.x, self.a.b, self[i]
        case outerVar              // bare identifier not in locals
        case typeStaticMember      // Type.x where Type is uppercase
        case outerMember(root: String, path: [String]) // outer.x, outer.a.b, outer[i]
        case local                 // bare identifier, or a chain rooted at one, in locals
        case unknown
    }

    private func classifyLHS(_ expr: ExprSyntax, locals: Set<String>) -> LHSKind {
        if let ident = expr.as(DeclReferenceExprSyntax.self) {
            return locals.contains(ident.baseName.text) ? .local : .outerVar
        }
        guard let (root, path) = storagePath(of: expr), !path.isEmpty else { return .unknown }
        if root == "self" { return .selfMember }
        if root.first?.isUppercase == true { return .typeStaticMember }
        if locals.contains(root) { return .local }
        return .outerMember(root: root, path: path)
    }

    // MARK: Outer-member escape: is the stored pointer read after its block returns?

    /// Decides whether a pointer stored into `root.path` can be read after the with-block that
    /// lent it has returned.
    ///
    /// The rule is textual and deliberately simple, because it has to be predictable to the
    /// person reading the diagnostic:
    ///
    /// 1. **The lending block.** The pointer is valid until the with-block that *bound* it
    ///    returns — for `outer.baseAddress` assigned inside an inner block, that is the outer
    ///    one. A name the stack cannot place (a local alias) is charged to the innermost block,
    ///    which is the conservative choice: the earliest end.
    /// 2. **The root's home.** `root` is looked up outward from that block to the nearest
    ///    declaration of it — a `var`/`let` or `guard let` earlier in an enclosing block, a
    ///    closure parameter, or an `if`/`while`/`for` binding. If none is found before the
    ///    enclosing function, the root is a parameter, a property or a global, and it outlives
    ///    the function: the store escapes regardless of what follows, and this returns `true`.
    /// 3. **Later reads.** Otherwise the store escapes if the home scope references `root`
    ///    textually after the lending block's call ends, or anywhere inside a loop that lies
    ///    between the block and the home (the next iteration runs it after the block). The
    ///    block's own closure is excluded: everything there runs while the pointer is live.
    /// 4. **Which references count.** A reference reads the stored pointer unless its member
    ///    path is disjoint from the stored one (`stream.total_out` after storing
    ///    `stream.next_in`), or it is the target of a plain `=` that overwrites the stored path
    ///    or a prefix of it. A bare `root`, `&root` or `root.method()` counts: the whole value
    ///    is handed over. A subscript is treated as matching any element.
    ///
    /// What it does not see, by construction: a `defer` written *before* the block (it runs
    /// at scope exit, but `defer { inflateEnd(&stream) }` is teardown and is the idiom the
    /// correct shape uses), reads through another variable that aliases `root`, and the
    /// `else` branch of an `if` whose `then` branch holds the block (counted, conservatively).
    private func storedPointerOutlivesBlock(
        rhs: ExprSyntax, tracked: Set<String>, root: String, path: [String]
    ) -> Bool {
        guard let lender = lendingScope(of: rhs, tracked: tracked) else { return true }
        let blockNode: Syntax = lender.closure.parent.map { Syntax($0) } ?? Syntax(lender.closure)
        guard let home = homeScope(of: root, from: blockNode) else { return true }

        let blockRange = lender.closure.position..<lender.closure.endPosition
        let afterBlock = blockNode.endPosition
        let loopRanges = home.loops.map { $0.position..<$0.endPosition }

        let finder = RootReferenceFinder(root: root)
        finder.walk(home.scope)
        return finder.references.contains { reference in
            let at = reference.position
            if blockRange.contains(at) { return false }
            let isLater = at >= afterBlock || loopRanges.contains { $0.contains(at) }
            return isLater && referenceReadsStoredPath(reference, stored: path)
        }
    }

    /// The with-block whose lifetime bounds the pointer in `rhs`.
    private func lendingScope(of rhs: ExprSyntax, tracked: Set<String>) -> WithScope? {
        let names = TrackedNameCollector(tracked: tracked)
        names.walk(rhs)
        var lender: Int?
        for name in names.found {
            let owner = withScopes.lastIndex { $0.bound.contains(name) } ?? (withScopes.count - 1)
            lender = max(lender ?? owner, owner)
        }
        guard let index = lender, withScopes.indices.contains(index) else { return withScopes.last }
        return withScopes[index]
    }

    /// The scope that declares `root`, searched outward from `start`, and the loops crossed on
    /// the way. `nil` when the search reaches a function boundary first.
    private func homeScope(of root: String, from start: Syntax) -> (scope: Syntax, loops: [Syntax])? {
        var loops: [Syntax] = []
        var child = start
        var current = start.parent
        while let node = current {
            if let list = node.as(CodeBlockItemListSyntax.self),
               declaresBefore(root, in: list, child: child) {
                return (Syntax(list), loops)
            }
            if let closure = node.as(ClosureExprSyntax.self),
               extractClosureBoundNames(closure).contains(root) {
                return (Syntax(closure), loops)
            }
            if let ifExpr = node.as(IfExprSyntax.self), conditionsBind(root, ifExpr.conditions) {
                return (Syntax(ifExpr), loops)
            }
            if let whileStmt = node.as(WhileStmtSyntax.self) {
                if conditionsBind(root, whileStmt.conditions) { return (Syntax(whileStmt), loops) }
                loops.append(node)
            }
            if let forStmt = node.as(ForStmtSyntax.self) {
                if patternBinds(root, forStmt.pattern) { return (Syntax(forStmt), loops) }
                loops.append(node)
            }
            if node.is(RepeatStmtSyntax.self) {
                loops.append(node)
            }
            if node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self)
                || node.is(AccessorDeclSyntax.self) || node.is(DeinitializerDeclSyntax.self)
                || node.is(SubscriptDeclSyntax.self) || node.is(MemberBlockSyntax.self) {
                return nil
            }
            child = node
            current = node.parent
        }
        return nil
    }

    private func declaresBefore(_ root: String, in list: CodeBlockItemListSyntax, child: Syntax) -> Bool {
        for item in list {
            if item.id == child.id { return false }
            if let decl = item.item.as(VariableDeclSyntax.self),
               decl.bindings.contains(where: { patternBinds(root, $0.pattern) }) {
                return true
            }
            if let guardStmt = item.item.as(GuardStmtSyntax.self), conditionsBind(root, guardStmt.conditions) {
                return true
            }
        }
        return false
    }

    private func conditionsBind(_ root: String, _ conditions: ConditionElementListSyntax) -> Bool {
        conditions.contains { element in
            guard let binding = element.condition.as(OptionalBindingConditionSyntax.self) else { return false }
            return patternBinds(root, binding.pattern)
        }
    }

    private func patternBinds(_ root: String, _ pattern: PatternSyntax) -> Bool {
        let names = PatternNameCollector(viewMode: .sourceAccurate)
        names.walk(pattern)
        return names.names.contains(root)
    }

    /// Whether a later reference to the root can read the pointer stored at `stored`.
    private func referenceReadsStoredPath(_ reference: DeclReferenceExprSyntax, stored: [String]) -> Bool {
        var path: [String] = []
        var node = Syntax(reference)
        while let parent = node.parent {
            if let member = parent.as(MemberAccessExprSyntax.self), member.base?.id == node.id {
                path.append(member.declName.baseName.text)
            } else if let subscriptCall = parent.as(SubscriptCallExprSyntax.self),
                      subscriptCall.calledExpression.id == node.id {
                path.append("[]")
            } else if !parent.is(ForceUnwrapExprSyntax.self), !parent.is(OptionalChainingExprSyntax.self) {
                break
            }
            node = parent
        }
        // `root.reset()` hands the whole value to a method: it is a use of `root`, not of a field.
        if let call = node.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == node.id,
           let last = path.last, last != "[]" {
            path.removeLast()
        }
        guard pathsOverlap(path, stored) else { return false }
        // `root.field = …` over the stored path or a prefix of it replaces the pointer unread.
        if path.count <= stored.count, isAssignmentTarget(node) { return false }
        return true
    }

    private func pathsOverlap(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != "[]" && right != "[]" && left != right {
            return false
        }
        return true
    }

    private func isAssignmentTarget(_ node: Syntax) -> Bool {
        guard let list = node.parent?.as(ExprListSyntax.self) else { return false }
        let elements = Array(list)
        guard let index = elements.firstIndex(where: { $0.id == node.id }), index + 1 < elements.count else {
            return false
        }
        return elements[index + 1].is(AssignmentExprSyntax.self)
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
            complianceRecords.append(ComplianceRecord(
                ruleId: "pointer-escape",
                annotation: "Allowed by configuration: \(functionName)",
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
            filePath: fileName,
            lineNumber: line(of: node),
            columnNumber: 1,
            ruleId: "pointer-escape.return-from-with-block",
            suggestedFix: "Return the dereferenced value (e.g. ptr.pointee) instead of the pointer itself."
        ))
    }
    private func emitAssignedToOuterCapture(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer escapes by assignment to a variable outside the with-block",
            filePath: fileName,
            lineNumber: line(of: node),
            columnNumber: 1,
            ruleId: "pointer-escape.assigned-to-outer-capture",
            suggestedFix: "Copy the pointee value instead of the pointer."
        ))
    }
    private func emitAssignedToOuterMember(at node: some SyntaxProtocol, root: String) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer is stored into '\(root)', which is read after the with-block returns and the memory is no longer lent",
            filePath: fileName,
            lineNumber: line(of: node),
            columnNumber: 1,
            ruleId: "pointer-escape.assigned-to-outer-member",
            suggestedFix: "Make every use of '\(root)' that reads the pointer inside the with-block (nest the blocks when there are several buffers), or clear the field before the block returns."
        ))
    }
    private func emitStoredInProperty(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer escapes by being stored in a property",
            filePath: fileName,
            lineNumber: line(of: node),
            columnNumber: 1,
            ruleId: "pointer-escape.stored-in-property",
            suggestedFix: "Store the pointee value or a Sendable copy instead."
        ))
    }
    private func emitAppendedToOuterCollection(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer escapes by being appended/inserted into a collection outside the with-block",
            filePath: fileName,
            lineNumber: line(of: node),
            columnNumber: 1,
            ruleId: "pointer-escape.appended-to-outer-collection",
            suggestedFix: "Append the pointee value, not the pointer."
        ))
    }
    private func emitPassedAsInout(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "pointer escapes by being passed alongside an inout outer variable",
            filePath: fileName,
            lineNumber: line(of: node),
            columnNumber: 1,
            ruleId: "pointer-escape.passed-as-inout",
            suggestedFix: "Avoid passing the pointer to a function that may store it via inout."
        ))
    }
    private func emitStoredClosure(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: "closure literal captures a pointer that becomes invalid after the with-block",
            filePath: fileName,
            lineNumber: line(of: node),
            columnNumber: 1,
            ruleId: "pointer-escape.stored-closure-captures-pointer",
            suggestedFix: "Capture the pointee value (or copy it into a Sendable wrapper) before storing the closure."
        ))
    }
    private func emitCapturedByEscapingClosure(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "pointer captured by an escaping closure may be used after the with-block ends",
            filePath: fileName,
            lineNumber: line(of: node),
            columnNumber: 1,
            ruleId: "pointer-escape.captured-by-escaping-closure",
            suggestedFix: "Use the synchronous variant or copy the pointee value before capturing."
        ))
    }
    private func emitOpaqueRoundtrip(at node: some SyntaxProtocol) {
        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "pointer round-trips through OpaquePointer; the underlying memory is invalid after the with-block",
            filePath: fileName,
            lineNumber: line(of: node),
            columnNumber: 1,
            ruleId: "pointer-escape.opaque-roundtrip",
            suggestedFix: "Keep both the typed and opaque forms inside the same with-block."
        ))
    }
}

// MARK: - Outer-member support

/// One `withUnsafe*` closure on the analysis stack, with the names it binds.
struct WithScope {
    let closure: ClosureExprSyntax
    let bound: Set<String>
}

/// The variable an assignment target is rooted at, and the path from it to the stored slot.
///
/// `stream.next_in` is `("stream", ["next_in"])`, `outer.a.b` is `("outer", ["a", "b"])`, and
/// `buf[0]` is `("buf", ["[]"])` — any element, since the index is not modelled. `!` and `?`
/// are transparent. Returns `nil` when the chain is not rooted at a plain name.
///
/// - Parameter expr: The assignment target.
/// - Returns: The root name and member path, or `nil`.
func storagePath(of expr: ExprSyntax) -> (root: String, path: [String])? {
    var path: [String] = []
    var current = expr
    while let (inner, component) = storageStep(current) {
        if let component { path.insert(component, at: 0) }
        current = inner
    }
    guard let root = current.as(DeclReferenceExprSyntax.self) else { return nil }
    return (root.baseName.text, path)
}

/// One step inward along an assignment target: the inner expression, and the path component
/// the step crossed (`nil` for `!` and `?`). `nil` once nothing more can be peeled.
private func storageStep(_ expr: ExprSyntax) -> (ExprSyntax, String?)? {
    if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
        return (base, member.declName.baseName.text)
    }
    if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) {
        return (subscriptCall.calledExpression, "[]")
    }
    if let unwrap = expr.as(ForceUnwrapExprSyntax.self) {
        return (unwrap.expression, nil)
    }
    if let chain = expr.as(OptionalChainingExprSyntax.self) {
        return (chain.expression, nil)
    }
    return nil
}

/// Every reference to a name as a value — not as a member name after a dot.
private final class RootReferenceFinder: SyntaxVisitor {
    let root: String
    var references: [DeclReferenceExprSyntax] = []
    init(root: String) {
        self.root = root
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if node.baseName.text == root,
           node.parent?.as(MemberAccessExprSyntax.self)?.declName.id != node.id {
            references.append(node)
        }
        return .skipChildren
    }
}

/// The tracked pointer names an expression mentions.
private final class TrackedNameCollector: SyntaxVisitor {
    let tracked: Set<String>
    var found: Set<String> = []
    init(tracked: Set<String>) {
        self.tracked = tracked
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if tracked.contains(node.baseName.text) { found.insert(node.baseName.text) }
        return .skipChildren
    }
}

/// The names a pattern binds (`stream`, `(a, b)`, `var s`).
private final class PatternNameCollector: SyntaxVisitor {
    var names: Set<String> = []
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text)
        return .skipChildren
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

/// Strips the markers that wrap an expression without changing what it evaluates to.
///
/// `try read(into: raw)` is a `TryExprSyntax` around the call, and `(read(into: raw))` a tuple
/// around it. Both mean exactly what the call means; without unwrapping, a `try` in front of a
/// borrowing call is enough to make the analysis fall back to "mentions a pointer anywhere",
/// which is how the same code passed unthrown and failed thrown.
///
/// - Parameter expr: The expression to unwrap.
/// - Returns: The expression inside the effect markers and redundant parentheses.
func unwrappingEffects(_ expr: ExprSyntax) -> ExprSyntax {
    if let tried = expr.as(TryExprSyntax.self) {
        return unwrappingEffects(tried.expression)
    }
    if let awaited = expr.as(AwaitExprSyntax.self) {
        return unwrappingEffects(awaited.expression)
    }
    // A single-element tuple with no label is parentheses, not a tuple.
    if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
        let only = tuple.elements.first, only.label == nil
    {
        return unwrappingEffects(only.expression)
    }
    return expr
}

/// True if the expression **evaluates to** a tracked pointer — which is a narrower question
/// than whether one appears inside it.
///
/// `read(into: raw)` returns an `Int`. The pointer is borrowed for the duration of the call and
/// is not part of the result, so a with-block returning that expression lets nothing escape.
/// Treating any mention as an escape flags every syscall wrapper ever written, and the fixes it
/// invites — hoisting the call into a `var` outside the block, splitting one line into three —
/// are worse code written to satisfy a checker.
///
/// A call is therefore transparent to its arguments, with two exceptions, both of which return
/// a pointer rather than merely accepting one: an initializer of a pointer type, and an
/// argument label that hands the memory over instead of copying from it.
///
/// - Parameters:
///   - expr: The expression under test.
///   - tracked: The pointer names currently in scope.
/// - Returns: `true` when the expression's value carries a tracked pointer.
func isPointerExpression(_ expr: ExprSyntax, tracked: Set<String>) -> Bool {
    guard let call = unwrappingEffects(expr).as(FunctionCallExprSyntax.self) else {
        return expressionContainsTrackedPointer(expr, tracked: tracked)
    }

    if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
        // A method that consumes a buffer to produce a value — `.reduce`, `.map` — returns the
        // value, not the buffer. Its receiver being the pointer is the point of calling it.
        if pointerValueMethods.contains(member.declName.baseName.text) {
            return false
        }
        // Anything else reached through the pointer — `raw.baseAddress`, `p.advanced(by:)` — is
        // the pointer's own value coming back out.
        if expressionContainsTrackedPointer(call.calledExpression, tracked: tracked) {
            return true
        }
    }

    let argumentsCarryPointer = call.arguments.contains {
        expressionContainsTrackedPointer($0.expression, tracked: tracked)
    }
    guard argumentsCarryPointer else { return false }

    // An initializer is treated as keeping what it is handed. `Holder(ptr: p)` stores it,
    // `UnsafeRawBufferPointer(p)` rewraps it, and `Data(p)` copies it — and nothing in the
    // syntax distinguishes the three. The conservative reading is the safe one, and the
    // allowlist is how a caller says a particular type only borrows.
    if isInitializerCall(call) { return true }

    // An ordinary function returns whatever it returns; the pointer went in as a borrow. That a
    // function might *store* it is a real risk, and a different rule's job — the conservative
    // fallback on the call itself, which the allowlist also governs. Answering it here too
    // would report one fault twice, under a rule that describes something else.
    return call.arguments.contains { argument in
        guard let label = argument.label?.text,
            pointerRetainingArgumentLabels.contains(label)
        else { return false }
        return expressionContainsTrackedPointer(argument.expression, tracked: tracked)
    }
}

/// Whether a call is constructing a value rather than invoking a function.
///
/// Judged by Swift's naming convention, which is all the syntax offers: a callee that is a bare
/// capitalised identifier, or a member chain ending in one, is a type being initialised.
///
/// - Parameter call: The call to classify.
/// - Returns: `true` when the callee names a type.
func isInitializerCall(_ call: FunctionCallExprSyntax) -> Bool {
    let name: String
    if let identifier = call.calledExpression.as(DeclReferenceExprSyntax.self) {
        name = identifier.baseName.text
    } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
        // `Foo.init(…)` names the type one level up; `foo.bar(…)` does not.
        name = member.declName.baseName.text == "init"
            ? (member.base?.trimmedDescription ?? "")
            : member.declName.baseName.text
    } else {
        return false
    }
    return name.first?.isUppercase == true
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
        override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
            // `buf[i]` is an element — a value, like `.pointee`. A range subscript is not:
            // `buf[0..<n]` is a slice that still points into the buffer.
            guard isElementSubscript(node) else { return .visitChildren }
            for arg in node.arguments {
                walk(arg.expression)
            }
            return .skipChildren
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

/// Whether a subscript reads one element rather than a slice.
///
/// One unlabelled index that is not a range (`..<`, `...`, or a one-sided form) reads an
/// element. Anything else — a range, a labelled subscript, several indices — is assumed to
/// produce something that may still refer to the subscripted memory.
///
/// - Parameter node: The subscript expression.
/// - Returns: `true` for a single-element read.
func isElementSubscript(_ node: SubscriptCallExprSyntax) -> Bool {
    guard node.arguments.count == 1, let only = node.arguments.first, only.label == nil else {
        return false
    }
    return !only.expression.trimmedDescription.contains("..")
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
