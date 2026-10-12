import QualityGateCore
import SwiftSyntax

/// One XML entity finding, before it has a location or has met an acknowledgement.
///
/// The rules decide *what* is wrong; ``SecurityVisitor`` decides *where*, and sends every
/// finding through its `report(_:)` so a `// SECURITY:` reason is validated and recorded the
/// same way it is for every other security rule.
struct XMLEntityFinding {
    /// `security.xml-external-entities` or `security.xml-entity-expansion`.
    let ruleId: String
    /// Error for a configuration with no safe reading; warning where the rule cannot see enough.
    let severity: Diagnostic.Severity
    /// What was found, ending with the bracketed CWE.
    let message: String
    /// The change that clears it.
    let suggestedFix: String
    /// Where the finding is reported.
    let anchor: Syntax

    /// Whether this is an external-entity load at error — the `K` of the coverage note.
    var configuresExternalLoad: Bool {
        ruleId == XMLEntityRules.externalRule && severity == .error
    }
}

/// XML parse sites counted for the `security.xml-coverage` note.
///
/// A tripwire that finds nothing must still say what it looked at: *examined 9 · 9 XMLParser*
/// is a statement about a portfolio, and silence is not.
struct XMLSiteCounts: Sendable, Equatable {
    /// `XMLParser(data:)`, `XMLParser(contentsOf:)`, `XMLParser(stream:)`.
    var xmlParser = 0
    /// `XMLDocument(data:)`, `XMLDocument(contentsOf:)`, `XMLDocument(xmlString:)`.
    var xmlDocument = 0
    /// libxml2 read and parse entry points.
    var libxml2 = 0
    /// External-entity findings at error, reported or acknowledged.
    var configuredToLoad = 0

    /// Every parse site, of any kind.
    var total: Int { xmlParser + xmlDocument + libxml2 }

    /// Adds another file's counts to these.
    mutating func add(_ other: XMLSiteCounts) {
        xmlParser += other.xmlParser
        xmlDocument += other.xmlDocument
        libxml2 += other.libxml2
        configuredToLoad += other.configuredToLoad
    }
}

/// `security.xml-external-entities` (CWE-611) and `security.xml-entity-expansion` (CWE-776).
///
/// Name-matching on syntax, one expression at a time: an assignment, a call, a member access, a
/// reference, a delegate method. Nothing is carried between statements, so a parser configured
/// by a factory or options built across several lines are not seen — the proposal lists what
/// that misses. See `quality-gate-swift-project/plans/proposals/AnEntityIsAFileRead.md`.
enum XMLEntityRules {

    static let externalRule = "security.xml-external-entities"
    static let expansionRule = "security.xml-entity-expansion"

    /// `XMLNode.Options` members that load external entities. There is no safe spelling of
    /// either: both fetch something the document named.
    static let loadingOptions: Set<String> = [
        "nodeLoadExternalEntitiesAlways", "nodeLoadExternalEntitiesSameOriginOnly",
    ]

    /// The option that stops `XMLDocument` reading an entity or an XInclude. Measured.
    static let refusingOption = "nodeLoadExternalEntitiesNever"

    /// libxml2 flags that substitute entities or load a DTD from outside the document.
    static let entityFlags: Set<String> = [
        "XML_PARSE_NOENT", "XML_PARSE_DTDLOAD", "XML_PARSE_DTDATTR", "XML_PARSE_DTDVALID",
        "XML_PARSE_XINCLUDE",
    ]

    /// The libxml2 flag that removes its entity-amplification limits.
    static let hugeFlag = "XML_PARSE_HUGE"

    /// libxml2 entry points that parse a document, for the coverage count only.
    static let libxml2Parsers: Set<String> = [
        "xmlReadMemory", "xmlReadFile", "xmlReadDoc", "xmlReadFd", "xmlReadIO",
        "xmlCtxtReadMemory", "xmlCtxtReadFile", "xmlCtxtReadDoc", "xmlCtxtReadFd", "xmlCtxtReadIO",
        "xmlParseMemory", "xmlParseFile", "xmlParseDoc", "xmlReaderForMemory", "xmlReaderForFile",
        "xmlSAXUserParseMemory", "xmlSAXUserParseFile", "xmlCreatePushParserCtxt",
    ]

    /// The `XMLDocument` initialiser labels that parse input. `rootElement:` builds a tree.
    private static let parsingLabels: Set<String> = ["data", "contentsOf", "xmlString"]

    private static let cwe611 = "[CWE-611]"
    private static let cwe776 = "[CWE-776]"

    // MARK: - Assignments: XMLParser properties

    /// `x.shouldResolveExternalEntities = <not false>` and `x.externalEntityResolvingPolicy = <not .never>`.
    ///
    /// Decided at runtime is not `false`. `.noNetwork` is flagged: a local file is what XXE reads.
    static func assignment(_ node: SequenceExprSyntax) -> XMLEntityFinding? {
        let elements = Array(node.elements)
        guard elements.count == 3,
              elements[1].is(AssignmentExprSyntax.self),
              let member = elements[0].as(MemberAccessExprSyntax.self) else { return nil }
        let property = member.declName.baseName.text
        let value = elements[2]

        switch property {
        case "shouldResolveExternalEntities":
            if let literal = value.as(BooleanLiteralExprSyntax.self),
               literal.literal.tokenKind == .keyword(.false) {
                return nil
            }
            return XMLEntityFinding(
                ruleId: externalRule, severity: .error,
                message: "XMLParser.shouldResolveExternalEntities is set to something other than false. "
                    + "Swift's open-source Foundation adds libxml2's DTD-loading flag on this property, so "
                    + "a document can name a file or URL and have it read. \(cwe611)",
                suggestedFix: "Leave shouldResolveExternalEntities at its default of false.",
                anchor: Syntax(node))
        case "externalEntityResolvingPolicy":
            if let policy = value.as(MemberAccessExprSyntax.self), policy.declName.baseName.text == "never" {
                return nil
            }
            return XMLEntityFinding(
                ruleId: externalRule, severity: .error,
                message: "XMLParser.externalEntityResolvingPolicy is set to something other than .never. "
                    + ".noNetwork still loads a local file, and a local file is what an external entity "
                    + "reads. \(cwe611)",
                suggestedFix: "Leave externalEntityResolvingPolicy at its default of .never.",
                anchor: Syntax(node))
        default:
            return nil
        }
    }

    // MARK: - Calls

    /// Whether `call` is an `XMLDocument` initialiser that parses input.
    static func isParsingXMLDocument(_ call: FunctionCallExprSyntax) -> Bool {
        let callee = call.calledExpression.trimmedDescription
        let named = callee == "XMLDocument" || callee.hasSuffix(".XMLDocument")
            || callee == "XMLDocument.init" || callee.hasSuffix(".XMLDocument.init")
        guard named, let label = call.arguments.first?.label?.text else { return false }
        return parsingLabels.contains(label)
    }

    /// Whether `call` constructs an `XMLParser` from input.
    static func isXMLParserConstruction(_ call: FunctionCallExprSyntax) -> Bool {
        let callee = call.calledExpression.trimmedDescription
        let named = callee == "XMLParser" || callee.hasSuffix(".XMLParser")
            || callee == "XMLParser.init" || callee.hasSuffix(".XMLParser.init")
        return named && !call.arguments.isEmpty
    }

    /// The libxml2 parse entry point `call` names, if it names one.
    static func isLibxml2Parse(_ call: FunctionCallExprSyntax) -> Bool {
        guard let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text else { return false }
        return libxml2Parsers.contains(name)
    }

    /// Findings on a call: an `XMLDocument` parse (611 and 776), or `xmlSubstituteEntitiesDefault`.
    static func call(_ node: FunctionCallExprSyntax) -> [XMLEntityFinding] {
        if let name = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           name == "xmlSubstituteEntitiesDefault" {
            if let only = node.arguments.first?.expression.as(IntegerLiteralExprSyntax.self),
               node.arguments.count == 1, only.literal.text == "0" {
                return []
            }
            return [XMLEntityFinding(
                ruleId: externalRule, severity: .error,
                message: "xmlSubstituteEntitiesDefault turns on entity substitution for every libxml2 parse "
                    + "in the process, external entities included. \(cwe611)",
                suggestedFix: "Remove the call, or pass 0.",
                anchor: Syntax(node))]
        }
        guard isParsingXMLDocument(node) else { return [] }
        var findings: [XMLEntityFinding] = []
        if let external = documentOptions(node) { findings.append(external) }
        if !hasDTDRefusal(before: node) {
            findings.append(XMLEntityFinding(
                ruleId: expansionRule, severity: .warning,
                message: "XMLDocument parses a document with no check for a DTD before it. No XMLNode option "
                    + "stops internal entity expansion: 512 bytes of nested entities expanded to 10⁹ bytes "
                    + "in 1.6 s when measured. \(cwe776)",
                suggestedFix: "Refuse a document containing \"<!DOCTYPE\" in a guard before the parse, use "
                    + "XMLParser, or acknowledge with // SECURITY: <why the input is trusted>.",
                anchor: Syntax(node)))
        }
        return findings
    }

    /// Clause (c) and (g): what an `XMLDocument` parse's `options:` argument says about entities.
    private static func documentOptions(_ node: FunctionCallExprSyntax) -> XMLEntityFinding? {
        let fix = "Add .nodeLoadExternalEntitiesNever to the options; it costs nothing where no entity "
            + "is expected, and it stops both the entity and the XInclude read."
        guard let options = node.arguments.first(where: { $0.label?.text == "options" })?.expression else {
            return XMLEntityFinding(
                ruleId: externalRule, severity: .error,
                message: "XMLDocument parses with its default options, and on macOS the default loads "
                    + "every external entity that does not need the network: a document that declares "
                    + "one reads a local file into its own text. .nodeLoadExternalEntitiesNever stops it. "
                    + "\(cwe611)",
                suggestedFix: fix, anchor: Syntax(node))
        }
        let names = optionNames(options)
        if let loading = names.visible.first(where: loadingOptions.contains) {
            return XMLEntityFinding(
                ruleId: externalRule, severity: .error,
                message: "XMLDocument parses with .\(loading), which loads external entities the document "
                    + "names. \(cwe611)",
                suggestedFix: "Replace it with .nodeLoadExternalEntitiesNever.", anchor: Syntax(node))
        }
        if names.visible.contains(refusingOption) { return nil }
        if names.opaque {
            return XMLEntityFinding(
                ruleId: externalRule, severity: .warning,
                message: "XMLDocument parses with options that are not visible here, so whether "
                    + ".nodeLoadExternalEntitiesNever is among them cannot be checked. Without it the "
                    + "default loads local external entities. \(cwe611)",
                suggestedFix: "Write the options as a literal at the call, including "
                    + ".nodeLoadExternalEntitiesNever.", anchor: Syntax(node))
        }
        return XMLEntityFinding(
            ruleId: externalRule, severity: .error,
            message: "XMLDocument parses without .nodeLoadExternalEntitiesNever, and on macOS the default "
                + "loads every external entity that does not need the network: a document that declares "
                + "one reads a local file into its own text. \(cwe611)",
            suggestedFix: fix, anchor: Syntax(node))
    }

    /// The member names an option-set expression spells, and whether any part of it is not a name.
    private static func optionNames(_ expression: ExprSyntax) -> (visible: [String], opaque: Bool) {
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return ([member.declName.baseName.text], false)
        }
        guard let array = expression.as(ArrayExprSyntax.self) else { return ([], true) }
        var names: [String] = []
        var opaque = false
        for element in array.elements {
            if let member = element.expression.as(MemberAccessExprSyntax.self) {
                names.append(member.declName.baseName.text)
            } else {
                opaque = true
            }
        }
        return (names, opaque)
    }

    // MARK: - Member access: loading options outside a parse

    /// Clause (d): `.nodeLoadExternalEntitiesAlways` / `…SameOriginOnly` anywhere.
    ///
    /// Inside the `options:` of a parsing `XMLDocument` call the call reports it, so one site is
    /// one diagnostic.
    static func memberAccess(_ node: MemberAccessExprSyntax) -> XMLEntityFinding? {
        let name = node.declName.baseName.text
        guard loadingOptions.contains(name), !isInsideParseOptions(node) else { return nil }
        return XMLEntityFinding(
            ruleId: externalRule, severity: .error,
            message: "XMLNode.Options.\(name) loads external entities the document names. There is no "
                + "safe use of it. \(cwe611)",
            suggestedFix: "Use .nodeLoadExternalEntitiesNever.", anchor: Syntax(node))
    }

    private static func isInsideParseOptions(_ node: MemberAccessExprSyntax) -> Bool {
        var current = node.parent
        // Bounded: an option inside `options: [ … ]` is at most a few nodes from its argument.
        for _ in 0..<6 {
            guard let candidate = current else { return false }
            if let argument = candidate.as(LabeledExprSyntax.self) {
                guard argument.label?.text == "options",
                      let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) else { return false }
                return isParsingXMLDocument(call)
            }
            current = candidate.parent
        }
        return false
    }

    // MARK: - References: libxml2 flags

    /// Clause (e) and 4.2(a): a libxml2 flag that loads entities, or removes the expansion limits.
    static func reference(_ node: DeclReferenceExprSyntax) -> XMLEntityFinding? {
        let name = node.baseName.text
        if entityFlags.contains(name) {
            return XMLEntityFinding(
                ruleId: externalRule, severity: .error,
                message: "libxml2 flag \(name) substitutes entities or loads a DTD from outside the "
                    + "document. \(cwe611)",
                suggestedFix: "Remove \(name); pass XML_PARSE_NONET.", anchor: Syntax(node))
        }
        if name == hugeFlag {
            return XMLEntityFinding(
                ruleId: expansionRule, severity: .error,
                message: "libxml2 flag XML_PARSE_HUGE removes the parser's size and entity-amplification "
                    + "limits. \(cwe776)",
                suggestedFix: "Remove XML_PARSE_HUGE.", anchor: Syntax(node))
        }
        return nil
    }

    // MARK: - Delegate: the resolver hook

    /// Clause (f): `parser(_:resolveExternalEntityName:systemID:)` with a body that is not `nil`.
    static func function(_ node: FunctionDeclSyntax) -> XMLEntityFinding? {
        guard node.name.text == "parser", let body = node.body else { return nil }
        let labels = node.signature.parameterClause.parameters.map(\.firstName.text)
        guard labels == ["_", "resolveExternalEntityName", "systemID"] else { return nil }
        if body.statements.isEmpty || returnsOnlyNil(body.statements) { return nil }
        return XMLEntityFinding(
            ruleId: externalRule, severity: .warning,
            message: "An XMLParserDelegate resolves external entities. The hook exists to hand bytes "
                + "back to the parser for an entity the document named. \(cwe611)",
            suggestedFix: "Return nil, or acknowledge with // SECURITY: <the allow-list it consults>.",
            anchor: Syntax(node.funcKeyword))
    }

    private static func returnsOnlyNil(_ statements: CodeBlockItemListSyntax) -> Bool {
        guard statements.count == 1, let item = statements.first?.item else { return false }
        if item.as(ExprSyntax.self)?.is(NilLiteralExprSyntax.self) == true { return true }
        if let returned = item.as(ReturnStmtSyntax.self)?.expression {
            return returned.is(NilLiteralExprSyntax.self)
        }
        return false
    }

    // MARK: - DTD refusal

    /// Whether a `guard`, or an `if` whose body exits, tests for `"<!DOCTYPE"` or `"<!ENTITY"`
    /// before `node` in the body that contains it.
    ///
    /// A marker heuristic, and the proposal says so: it accepts a check on the wrong buffer.
    static func hasDTDRefusal(before node: some SyntaxProtocol) -> Bool {
        let scope = enclosingBody(of: node) ?? Syntax(node).root
        let finder = DTDRefusalFinder(before: node.position)
        finder.walk(scope)
        return finder.found
    }

    private static func enclosingBody(of node: some SyntaxProtocol) -> Syntax? {
        var current = node.parent
        while let candidate = current {
            if let function = candidate.as(FunctionDeclSyntax.self) { return function.body.map(Syntax.init) }
            if let initialiser = candidate.as(InitializerDeclSyntax.self) { return initialiser.body.map(Syntax.init) }
            if let accessor = candidate.as(AccessorDeclSyntax.self) { return accessor.body.map(Syntax.init) }
            if let closure = candidate.as(ClosureExprSyntax.self) { return Syntax(closure.statements) }
            current = candidate.parent
        }
        return nil
    }
}

/// Finds a DTD refusal that ends before a position.
private final class DTDRefusalFinder: SyntaxVisitor {
    private let limit: AbsolutePosition
    private(set) var found = false

    init(before limit: AbsolutePosition) {
        self.limit = limit
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.endPosition <= limit, Self.mentionsDTD(node.conditions) { found = true }
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        if node.endPosition <= limit, Self.mentionsDTD(node.conditions), Self.exits(node.body) { found = true }
        return .visitChildren
    }

    private static func mentionsDTD(_ conditions: ConditionElementListSyntax) -> Bool {
        conditions.tokens(viewMode: .sourceAccurate).contains { token in
            guard case .stringSegment(let text) = token.tokenKind else { return false }
            return text.contains("<!DOCTYPE") || text.contains("<!ENTITY")
        }
    }

    private static func exits(_ body: CodeBlockSyntax) -> Bool {
        body.statements.contains { item in
            item.item.is(ThrowStmtSyntax.self) || item.item.is(ReturnStmtSyntax.self)
        }
    }
}
