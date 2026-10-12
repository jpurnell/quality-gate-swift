import Testing
import SwiftSyntax
import SwiftParser
import SyntaxScope

// MARK: - LexicalScope

@Suite("SyntaxScope: LexicalScope")
struct LexicalScopeTests {
    @Test("A declared name is shadowed until its frame is popped")
    func declareThenPop() {
        var scope = LexicalScope()
        #expect(scope.shadows("x") == false)
        scope.push()
        scope.declare("x")
        #expect(scope.shadows("x") == true)
        scope.pop()
        #expect(scope.shadows("x") == false)
    }

    @Test("An outer frame's names are visible from an inner frame")
    func outerNamesAreVisibleInside() {
        var scope = LexicalScope()
        scope.declare("outer")
        scope.push()
        scope.declare("inner")
        #expect(scope.shadows("outer") == true)
        #expect(scope.shadows("inner") == true)
    }

    @Test("Popping the root frame is refused, so the scope stays usable")
    func poppingTheRootIsRefused() {
        var scope = LexicalScope()
        scope.declare("x")
        scope.pop()
        scope.pop()
        #expect(scope.shadows("x") == true)
        scope.declare("y")
        #expect(scope.shadows("y") == true)
    }

    @Test("A seeded scope binds the seed in its root frame")
    func seedIsBound() {
        var scope = LexicalScope(binding: ["parameter"])
        #expect(scope.shadows("parameter") == true)
        scope.push()
        scope.pop()
        #expect(scope.shadows("parameter") == true)
        #expect(scope.shadows("other") == false)
    }
}

// MARK: - Pattern names

@Suite("SyntaxScope: names a pattern binds")
struct BoundNamesTests {
    /// The first node of type `T` in `source`.
    private func first<T: SyntaxProtocol>(_ type: T.Type, in source: String) -> T? {
        let finder = FirstNodeFinder<T>(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        return finder.match
    }

    @Test("A tuple pattern binds each element")
    func tuplePattern() throws {
        let decl = try #require(first(VariableDeclSyntax.self, in: "let (a, b) = pair"))
        let pattern = try #require(decl.bindings.first?.pattern)
        #expect(boundNames(in: pattern) == ["a", "b"])
    }

    @Test("case let .x(y) binds y and not the case name")
    func expressionPatternUnderLet() throws {
        let condition = try #require(first(MatchingPatternConditionSyntax.self, in: "if case let .loaded(device) = state {}"))
        #expect(bindingNames(inMatching: condition.pattern) == ["device"])
    }

    @Test("In a matched pattern only what sits under let binds")
    func mixedPatternBindsOnlyUnderLet() throws {
        let condition = try #require(first(MatchingPatternConditionSyntax.self, in: "if case .loaded(let device, expected) = state {}"))
        #expect(bindingNames(inMatching: condition.pattern) == ["device"])
    }

    @Test("Conditions bind optional bindings, shorthand ones, and case patterns")
    func conditionList() throws {
        let ifExpr = try #require(first(IfExprSyntax.self, in: "if let a = x, let b, case let .some(c) = y, a > 0 {}"))
        #expect(boundNames(in: ifExpr.conditions) == ["a", "b", "c"])
    }

    @Test("A closure binds its captures and parameters, but not self")
    func closureNames() throws {
        let closure = try #require(first(ClosureExprSyntax.self, in: "run { [weak self, log, link = self.link] first, second in }"))
        #expect(boundNames(of: closure) == ["log", "link", "first", "second"])
    }

    @Test("A closure with a typed parameter clause binds the internal names")
    func closureTypedParameters() throws {
        let closure = try #require(first(ClosureExprSyntax.self, in: "run { (value: Int, _ other: Int) in }"))
        #expect(boundNames(of: closure) == ["value", "other"])
    }

    @Test("A catch with no pattern binds error; with one, its bindings")
    func catchNames() throws {
        let bare = try #require(first(CatchClauseSyntax.self, in: "do {} catch {}"))
        #expect(boundNames(of: bare) == ["error"])
        let typed = try #require(first(CatchClauseSyntax.self, in: "do {} catch let failure as Failure {}"))
        #expect(boundNames(of: typed) == ["failure"])
    }

    @Test("An accessor binds its explicit parameter, or the implicit one")
    func accessorNames() throws {
        let implicitSet = try #require(first(AccessorDeclSyntax.self, in: "var x: Int { set { } }"))
        #expect(boundNames(of: implicitSet) == ["newValue"])
        let explicitSet = try #require(first(AccessorDeclSyntax.self, in: "var x: Int { set(incoming) { } }"))
        #expect(boundNames(of: explicitSet) == ["incoming"])
        let didSet = try #require(first(AccessorDeclSyntax.self, in: "var x: Int = 0 { didSet { } }"))
        #expect(boundNames(of: didSet) == ["oldValue"])
        let getter = try #require(first(AccessorDeclSyntax.self, in: "var x: Int { get { 0 } }"))
        #expect(boundNames(of: getter) == [])
    }
}

// MARK: - visibleBindings(at:)

@Suite("SyntaxScope: bindings visible at a node")
struct VisibleBindingsTests {
    /// The bindings visible at the call to `probe()` in `source`.
    private func visible(_ source: String) throws -> Set<String> {
        final class Finder: SyntaxVisitor {
            var call: FunctionCallExprSyntax?
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                if node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "probe" {
                    call = node
                }
                return .visitChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: source))
        return visibleBindings(at: try #require(finder.call))
    }

    @Test("Earlier let and var statements of the enclosing list are visible")
    func earlierLocals() throws {
        let names = try visible("""
        func f() {
            let a = 1
            var (b, c) = (2, 3)
            probe()
        }
        """)
        #expect(names == ["a", "b", "c"])
    }

    @Test("A local declared after the node is not visible")
    func laterLocalIsNotVisible() throws {
        let names = try visible("""
        func f() {
            probe()
            let later = 1
        }
        """)
        #expect(names == [])
    }

    @Test("A local in a sibling block is not visible")
    func siblingBlockIsNotVisible() throws {
        let names = try visible("""
        func f(flag: Bool) {
            if flag { let hidden = 1 }
            do { let alsoHidden = 2 }
            probe()
        }
        """)
        #expect(names == ["flag"])
    }

    @Test("An earlier guard binds for the rest of the list")
    func guardBindings() throws {
        let names = try visible("""
        func f(x: Int?) {
            guard let value = x, case let .some(other) = x else { return }
            probe()
        }
        """)
        #expect(names == ["x", "value", "other"])
    }

    @Test("if conditions bind in the body and not in the else")
    func ifBindings() throws {
        let body = try visible("func f() { if let a = x, let b { probe() } }")
        #expect(body == ["a", "b"])
        let elseBody = try visible("func f() { if let a = x { } else { probe() } }")
        #expect(elseBody == [])
    }

    @Test("while conditions bind in the body")
    func whileBindings() throws {
        let names = try visible("func f() { while let next = iterator.next() { probe() } }")
        #expect(names == ["next"])
    }

    @Test("A for pattern binds in the body")
    func forBindings() throws {
        let single = try visible("func f() { for item in items { probe() } }")
        #expect(single == ["item"])
        let tuple = try visible("func f() { for (key, value) in pairs { probe() } }")
        #expect(tuple == ["key", "value"])
    }

    @Test("A catch clause binds its pattern or the implicit error")
    func catchBindings() throws {
        let implicit = try visible("func f() { do {} catch { probe() } }")
        #expect(implicit == ["error"])
        let explicit = try visible("func f() { do {} catch let failure as Failure { probe() } }")
        #expect(explicit == ["failure"])
    }

    @Test("A switch case binds its case-item patterns")
    func switchCaseBindings() throws {
        let names = try visible("""
        func f() {
            switch state {
            case .loaded(let device), .cached(let device): probe()
            default: break
            }
        }
        """)
        #expect(names == ["device"])
    }

    @Test("An enclosing closure binds its parameters and captures")
    func closureBindings() throws {
        let names = try visible("func f() { items.forEach { [log] item in probe() } }")
        #expect(names == ["log", "item"])
        let shorthand = try visible("func f() { run { [weak self] in probe() } }")
        #expect(shorthand == [])
    }

    @Test("Function, initializer and subscript parameters bind by their internal name")
    func parameterBindings() throws {
        let function = try visible("func f(with value: Int, other: Int) { probe() }")
        #expect(function == ["value", "other"])
        let initializer = try visible("struct S { init(seed: Int) { probe() } }")
        #expect(initializer == ["seed"])
        let subscripted = try visible("struct S { subscript(index: Int) -> Int { probe() } }")
        #expect(subscripted == ["index"])
    }

    @Test("An accessor binds newValue, oldValue, or its explicit parameter")
    func accessorBindings() throws {
        let setter = try visible("struct S { var x: Int { get { 0 } set { probe() } } }")
        #expect(setter == ["newValue"])
        let named = try visible("struct S { var x: Int { get { 0 } set(incoming) { probe() } } }")
        #expect(named == ["incoming"])
        let observer = try visible("struct S { var x: Int = 0 { didSet { probe() } } }")
        #expect(observer == ["oldValue"])
    }

    @Test("The walk stops at the enclosing type, so its members are never bindings")
    func stopsAtMemberBlock() throws {
        let names = try visible("""
        func outer(hidden: Int) {
            struct Local {
                var device = 0
                func f(shown: Int) { probe() }
            }
        }
        """)
        #expect(names == ["shown"])
    }

    @Test("Bindings accumulate through nested scopes")
    func nestedScopesAccumulate() throws {
        let names = try visible("""
        func f(parameter: Int) {
            let local = 1
            for item in items {
                if let unwrapped = item {
                    run { argument in probe() }
                }
            }
        }
        """)
        #expect(names == ["parameter", "local", "item", "unwrapped", "argument"])
    }
}

/// Finds the first node of one syntax type, in source order.
private final class FirstNodeFinder<Node: SyntaxProtocol>: SyntaxAnyVisitor {
    var match: Node?
    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        if match == nil, let typed = node.as(Node.self) { match = typed }
        return match == nil ? .visitChildren : .skipChildren
    }
}
