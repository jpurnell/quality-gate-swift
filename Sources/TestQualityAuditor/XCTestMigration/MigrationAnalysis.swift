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
    /// Tests whose leading skip becomes a trait, and the trait.
    private(set) var traits: [SyntaxIdentifier: String] = [:]
    /// Every name the file declares or refers to, so a new binding can avoid them all.
    private(set) var namesInUse: Set<String> = []
    /// Why this file cannot be converted, one finding per construct, at its line in the input.
    private(set) var declines: [Diagnostic] = []
    /// `XCTSkip…` references a trait has already accounted for.
    private var convertedSkips: Set<SyntaxIdentifier> = []
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
        namesInUse.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        namesInUse.insert(node.identifier.text)
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        namesInUse.insert(node.firstName.text)
        if let second = node.secondName { namesInUse.insert(second.text) }
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        namesInUse.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        namesInUse.insert(node.firstName.text)
        if let second = node.secondName { namesInUse.insert(second.text) }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        guard Self.inheritsXCTestCase(node) else { return .visitChildren }
        declineIfAvailabilityLimited(node.attributes, on: node.name.text, at: Syntax(node))
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
            declineIfAvailabilityLimited(node.attributes, on: "the extension of \(suite)", at: Syntax(node))
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
           Self.isDeclaredNonOptional(subject) || AssertionMapping.isThrownErrorParameter(subject) {
            keptCalls.insert(node.id)
            decline("\(callee)(\(subject.baseName.text)): `\(subject.baseName.text)` is not optional, so this can never fail. XCTest took `Any?`, which is why it compiled. State what the test means, or delete it. (As `#expect(x != nil)` it is a compiler warning, and on an existential it crashed swift-frontend 6.4.)",
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
        if !node.isMemberName { namesInUse.insert(node.baseName.text) }
        if !convertedSkips.contains(node.id), let note = MigrationResidue.note(for: node) {
            decline(note, at: Syntax(node))
        }
        return .visitChildren
    }

    // MARK: - Suites

    static func inheritsXCTestCase(_ node: ClassDeclSyntax) -> Bool {
        node.inheritanceClause?.inheritedTypes.contains {
            $0.type.trimmedDescription == "XCTestCase"
        } ?? false
    }

    /// Swift Testing refuses `@Suite` on a declaration carrying `@available`, and `@Test` inside
    /// one. The compiler says so only after the file has been rewritten.
    ///
    /// BusinessMathExcel had four suites marked `@available(*, deprecated)` so they could call
    /// deprecated translators without a warning. No rewrite of the attribute keeps that
    /// arrangement, so the file is declined and the reason says what the attribute was for.
    private func declineIfAvailabilityLimited(_ attributes: AttributeListSyntax, on subject: String, at node: Syntax) {
        guard let attribute = attributes.lazy.compactMap({ $0.as(AttributeSyntax.self) })
            .first(where: { $0.isNamed("available") })
        else { return }
        decline("\(attribute.trimmedDescription) on \(subject): Swift Testing refuses @Suite on a declaration marked @available, and @Test on anything inside one. If the attribute is there so the tests can call deprecated API without a warning, make those calls through a deprecated helper and remove the attribute from the suite.",
                at: node)
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
                decline("tearDown async: a deinit cannot be async. Move the work into the test, or into an actor the suite owns.",
                       at: Syntax(function))
                return nil
            }
            if let body = function.body, Self.containsUnhandledTry(Syntax(body)) {
                decline("tearDownWithError: a deinit cannot throw, and this one calls something that does. Handle the error inside it, or move the work into the test.",
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

            if let skip = SkipTrait.conversion(
                for: test, instanceMembers: inventory.instanceMemberNames[suite] ?? []) {
                traits[test.id] = skip.trait
                removedStatements.insert(skip.statement)
                convertedSkips.insert(skip.reference)
            }
        }
    }

    // MARK: - Declining

    /// Records a construct that stops this file's conversion.
    ///
    /// Called by the renderer too: some reasons are only known once an assertion is being
    /// written, such as an unwrap that cannot be bound ahead of the statement it sits in.
    func decline(_ message: String, at node: Syntax) {
        let location = node.startLocation(converter: converter)
        let finding = Diagnostic(
            severity: .error,
            message: message,
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "xctest-import",
            suggestedFix: "This file was not converted. Resolve this by hand, then run --fix again.")
        if !declines.contains(finding) { declines.append(finding) }
    }
}
