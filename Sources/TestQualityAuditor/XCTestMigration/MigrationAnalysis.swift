import QualityGateCore
import SwiftSyntax

/// What the conversion will do, decided before anything is rendered.
///
/// Every decision that needs to see more than one node is made here: whether a suite can be
/// a struct, what each test method is called afterwards, which statements disappear. The
/// renderer then applies them node by node without looking around.
final class MigrationAnalysis: SyntaxVisitor {

    /// Whether a converted suite is a value or a reference.
    enum SuiteKind {
        /// No lifecycle and no mutable stored state: `@Suite struct`.
        case structure
        /// `setUp`/`tearDown`, or a stored `var` a test may mutate: `@Suite final class`.
        case finalClass
    }

    /// What a lifecycle method becomes.
    enum Lifecycle {
        /// `setUp`, `setUpWithError`: `init()`, keeping `async`/`throws`.
        case initializer
        /// `tearDown`, `tearDownWithError` with nothing to throw: `deinit`.
        case deinitializer
    }

    let fileName: String
    private let converter: SourceLocationConverter
    private let inventory: SuiteInventory

    /// `XCTestCase` subclasses, and what each becomes.
    private(set) var suites: [SyntaxIdentifier: SuiteKind] = [:]
    /// Test methods, and their names afterwards.
    private(set) var testNames: [SyntaxIdentifier: String] = [:]
    /// Lifecycle methods, and what they become.
    private(set) var lifecycles: [SyntaxIdentifier: Lifecycle] = [:]
    /// Statements removed outright: `super.setUp()` and its relatives.
    private(set) var removedStatements: Set<SyntaxIdentifier> = []
    /// Assertions left exactly as written, because converting them would be wrong.
    private(set) var keptCalls: Set<SyntaxIdentifier> = []
    /// Functions this file declares `throws`, by base name.
    private(set) var throwingFunctions: Set<String> = []
    /// What was left for a person.
    private(set) var residue: [Diagnostic] = []
    /// Names already given to converted tests, per suite.
    private var givenNames: [String: Set<String>] = [:]

    /// Test methods counted independently of the conversion, which it must match one-for-one.
    var testMethodCount: Int { inventory.independentTestCount }

    init(tree: SourceFileSyntax, fileName: String) {
        self.fileName = fileName
        self.converter = SourceLocationConverter(fileName: fileName, tree: tree)
        self.inventory = SuiteInventory(tree)
        super.init(viewMode: .sourceAccurate)
        walk(tree)
    }

    // MARK: - Visiting

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.signature.effectSpecifiers?.throwsClause != nil {
            throwingFunctions.insert(node.name.text)
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        guard Self.inheritsXCTestCase(node) else { return .visitChildren }
        let members = node.memberBlock.members.map(\.decl)
        var hasLifecycle = false

        for member in members {
            guard let function = member.as(FunctionDeclSyntax.self) else { continue }
            if let lifecycle = classifyLifecycle(function) {
                lifecycles[function.id] = lifecycle
                hasLifecycle = true
            }
        }
        let kind: SuiteKind = hasLifecycle || Self.hasMutableStoredState(members) ? .finalClass : .structure
        suites[node.id] = kind
        nameTests(in: members, suite: node.name.text)
        return .visitChildren
    }

    /// An extension of a suite in this file holds tests XCTest ran, and they convert too.
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let suite = node.extendedType.trimmedDescription
        if inventory.suiteNames.contains(suite) {
            nameTests(in: node.memberBlock.members.map(\.decl), suite: suite)
        }
        return .visitChildren
    }

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        if Self.isSuperLifecycleCall(node.item) {
            removedStatements.insert(node.id)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression.trimmedDescription
        if callee == "XCTAssertNil" || callee == "XCTAssertNotNil",
           let subject = node.arguments.first?.expression.as(DeclReferenceExprSyntax.self),
           Self.isDeclaredNonOptional(subject) {
            keptCalls.insert(node.id)
            report("\(callee)(\(subject.baseName.text)): `\(subject.baseName.text)` is declared non-optional, so this can never fail. XCTest took `Any?`, which is why it compiled. State what the test means, or delete it. (As `#expect(x != nil)` it is a compiler warning, and on an existential it crashed swift-frontend 6.4.)",
                   at: Syntax(node))
        }
        return .visitChildren
    }

    /// Whether `reference` names a local binding written with a non-optional type annotation,
    /// declared before it in an enclosing block.
    private static func isDeclaredNonOptional(_ reference: DeclReferenceExprSyntax) -> Bool {
        let name = reference.baseName.text
        var current = Syntax(reference).parent
        while let node = current {
            if let items = node.as(CodeBlockItemListSyntax.self) {
                for item in items where item.position < reference.position {
                    guard let variable = item.item.as(VariableDeclSyntax.self) else { continue }
                    for binding in variable.bindings {
                        guard binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name,
                              let type = binding.typeAnnotation?.type
                        else { continue }
                        return !(type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self))
                    }
                }
            }
            if node.is(FunctionDeclSyntax.self) || node.is(ClosureExprSyntax.self) { return false }
            current = node.parent
        }
        return false
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if let note = MigrationResidue.note(for: node) {
            report(note, at: Syntax(node))
        }
        return .visitChildren
    }

    // MARK: - Suites

    static func inheritsXCTestCase(_ node: ClassDeclSyntax) -> Bool {
        node.inheritanceClause?.inheritedTypes.contains {
            $0.type.trimmedDescription == "XCTestCase"
        } ?? false
    }

    /// A stored `var` makes a struct suite uncompilable as soon as a test mutates it, so its
    /// presence decides the suite's kind: `final class` is always correct, a struct only sometimes.
    private static func hasMutableStoredState(_ members: [DeclSyntax]) -> Bool {
        members.contains { member in
            guard let variable = member.as(VariableDeclSyntax.self),
                  variable.bindingSpecifier.tokenKind == .keyword(.var),
                  !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
            else { return false }
            return variable.bindings.contains { binding in
                guard let accessors = binding.accessorBlock else { return true }
                guard case .accessors(let list) = accessors.accessors else { return false }
                return list.allSatisfy {
                    $0.accessorSpecifier.tokenKind == .keyword(.willSet)
                        || $0.accessorSpecifier.tokenKind == .keyword(.didSet)
                }
            }
        }
    }

    // MARK: - Lifecycle

    private func classifyLifecycle(_ function: FunctionDeclSyntax) -> Lifecycle? {
        guard function.signature.parameterClause.parameters.isEmpty,
              function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.override) }),
              !function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.class) })
        else { return nil }
        let effects = function.signature.effectSpecifiers
        switch function.name.text {
        case "setUp", "setUpWithError":
            return .initializer
        case "tearDown", "tearDownWithError":
            if effects?.asyncSpecifier != nil {
                report("tearDown async: a deinit cannot be async. Move the work into the test, or into an actor the suite owns.",
                       at: Syntax(function))
                return nil
            }
            if let body = function.body, Self.containsUnhandledTry(Syntax(body)) {
                report("tearDownWithError: a deinit cannot throw, and this one calls something that does. Handle the error inside it, or move the work into the test.",
                       at: Syntax(function))
                return nil
            }
            return .deinitializer
        default:
            return nil
        }
    }

    private static func isSuperLifecycleCall(_ item: CodeBlockItemSyntax.Item) -> Bool {
        guard case .expr(let expression) = item else { return false }
        let core = Operand.strip(expression).expression
        guard let call = core.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.base?.trimmedDescription == "super"
        else { return false }
        return ["setUp", "setUpWithError", "tearDown", "tearDownWithError"]
            .contains(member.declName.baseName.text)
    }

    private static func containsUnhandledTry(_ node: Syntax) -> Bool {
        // `try super.tearDownWithError()` is removed by the conversion, so it does not count.
        if let item = node.as(CodeBlockItemSyntax.self), isSuperLifecycleCall(item.item) { return false }
        if let tryExpr = node.as(TryExprSyntax.self), tryExpr.questionOrExclamationMark == nil {
            return true
        }
        if node.is(ClosureExprSyntax.self) || node.is(DoStmtSyntax.self) { return false }
        return node.children(viewMode: .sourceAccurate).contains { containsUnhandledTry($0) }
    }

    // MARK: - Names

    /// Names each test in `members`, avoiding every name the suite declares anywhere in the
    /// file and every name already given.
    private func nameTests(in members: [DeclSyntax], suite: String) {
        let tests = members.compactMap { $0.as(FunctionDeclSyntax.self) }.filter(SuiteInventory.isTestMethod)
        for test in tests {
            let original = test.name.text
            let taken = (inventory.memberNames[suite] ?? []).union(givenNames[suite] ?? [])
            let lowered = TestNameLowering.lowered(original)
            let name = lowered.flatMap { taken.contains($0) ? nil : $0 } ?? original
            givenNames[suite, default: []].insert(name)
            testNames[test.id] = name
        }
    }



    // MARK: - Residue

    private func report(_ message: String, at node: Syntax) {
        let location = node.startLocation(converter: converter)
        residue.append(Diagnostic(
            severity: .error,
            message: message,
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "xctest-import",
            suggestedFix: "Converted everything else in this file; this one needs a decision."))
    }
}
