import SwiftSyntax

/// What a file declares, gathered before the conversion decides anything.
///
/// Two of the conversion's decisions need the whole file at once. A test method lowered to
/// `value` must not collide with a `value` declared in an *extension* of the suite. And the
/// orphan check needs a count of test methods that does not share the conversion's blind
/// spots. In the SwiftExcelFunctions validation, five tests in `extension
/// WorkbookDecryptorTests` were missed by the conversion *and* by a count taken from it, so
/// the check passed a file that would have silently stopped running them.
struct SuiteInventory {

    /// Names of the file's `XCTestCase` subclasses.
    let suiteNames: Set<String>
    /// Every member name declared in each suite, across the class and its extensions.
    let memberNames: [String: Set<String>]
    /// The subset of ``memberNames`` that needs an instance: everything not `static` or `class`.
    let instanceMemberNames: [String: Set<String>]
    /// Parameterless `func test*` methods in *any* class or extension in the file.
    ///
    /// Deliberately wider than what the conversion handles. A test method in a class this
    /// file cannot see is an `XCTestCase` (a subclass of a project base class, say) is one
    /// XCTest may have run. Counting it means the file is refused rather than written with
    /// that test silently dropped.
    let independentTestCount: Int

    init(_ tree: SourceFileSyntax) {
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(tree)
        suiteNames = collector.suiteNames
        memberNames = collector.memberNames.filter { collector.suiteNames.contains($0.key) }
        instanceMemberNames = collector.instanceMemberNames.filter { collector.suiteNames.contains($0.key) }
        independentTestCount = collector.testMethods
    }

    /// Whether `function` has the shape XCTest discovers: `func test…()`, not static or private.
    static func isTestMethod(_ function: FunctionDeclSyntax) -> Bool {
        let name = function.name.text
        guard name.hasPrefix("test"), name.count > 4,
              function.signature.parameterClause.parameters.isEmpty,
              !function.modifiers.contains(where: {
                  [.keyword(.static), .keyword(.class), .keyword(.private), .keyword(.fileprivate)]
                      .contains($0.name.tokenKind)
              })
        else { return false }
        let next = name[name.index(name.startIndex, offsetBy: 4)]
        return next.isUppercase || next.isNumber || next == "_"
    }

    /// The names a member declares.
    static func declaredNames(_ member: DeclSyntax) -> [String] {
        if let function = member.as(FunctionDeclSyntax.self) { return [function.name.text] }
        if let variable = member.as(VariableDeclSyntax.self) {
            return variable.bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
        }
        return []
    }

    /// Whether `member` is declared `static` or `class`.
    static func isTypeLevel(_ member: DeclSyntax) -> Bool {
        let modifiers = member.as(FunctionDeclSyntax.self)?.modifiers
            ?? member.as(VariableDeclSyntax.self)?.modifiers
        return modifiers?.contains {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        } ?? false
    }

    private final class Collector: SyntaxVisitor {
        var suiteNames: Set<String> = []
        var memberNames: [String: Set<String>] = [:]
        var instanceMemberNames: [String: Set<String>] = [:]
        var testMethods = 0

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            if MigrationAnalysis.inheritsXCTestCase(node) { suiteNames.insert(node.name.text) }
            record(node.name.text, node.memberBlock)
            return .visitChildren
        }

        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            record(node.extendedType.trimmedDescription, node.memberBlock)
            return .visitChildren
        }

        private func record(_ typeName: String, _ block: MemberBlockSyntax) {
            for member in block.members.map(\.decl) {
                let names = SuiteInventory.declaredNames(member)
                memberNames[typeName, default: []].formUnion(names)
                if !SuiteInventory.isTypeLevel(member) {
                    instanceMemberNames[typeName, default: []].formUnion(names)
                }
                if let function = member.as(FunctionDeclSyntax.self), SuiteInventory.isTestMethod(function) {
                    testMethods += 1
                }
            }
        }
    }
}
