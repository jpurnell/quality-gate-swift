import Foundation
import SwiftSyntax

/// What one function body does that matters to the MetricKit reachability walk.
struct MetricKitFunctionFact {
    /// Function name, or `init` for an initializer.
    let name: String
    /// Name of the type (or extension) the function is declared in; `nil` for a free function.
    let owner: String?
    let isInitializer: Bool
    /// True when app start runs it directly: an `App` initializer or an application-launch hook.
    let isStartRoot: Bool
    /// Every identifier the body mentions (calls and type names alike).
    var referenced: Set<String> = []
    /// True when the body calls `MXMetricManager.shared.add` outside an inactive `#if` branch.
    var registers = false
}

/// A `didReceive(_:)` payload handler found in a type or extension.
struct MetricKitHandlerFact {
    enum Kind { case metric, diagnostic }
    let owner: String
    let kind: Kind
    /// False when the body only logs, prints, or does nothing.
    let passesPayloadOn: Bool
    let file: String
    let line: Int
}

/// A type that declares conformance to `MXMetricManagerSubscriber`.
struct MetricKitSubscriberFact {
    let name: String
    /// False when declared in a `#if canImport(MetricKit)` else-branch.
    let active: Bool
    let file: String
    let line: Int
}

/// Per-file facts the project-level MetricKit rules are decided from.
struct MetricKitFileFacts {
    var entryPoint: (file: String, line: Int)?
    var entryHints: Set<String> = []
    var subscribers: [MetricKitSubscriberFact] = []
    var handlers: [MetricKitHandlerFact] = []
    var functions: [MetricKitFunctionFact] = []
}

/// Collects the facts behind `logging.no-metrickit-subscriber` and
/// `logging.metrickit-payload-ignored` from one parsed file.
final class MetricKitFactsVisitor: SyntaxVisitor {
    private let file: String
    private let converter: SourceLocationConverter
    private let loggerNames: Set<String>
    private(set) var facts = MetricKitFileFacts()

    private struct TypeScope { let name: String; let isApp: Bool }
    private var typeStack: [TypeScope] = []
    private var functionStack: [Int] = []
    /// Depth of `#if` branches in which `canImport(MetricKit)` is known false.
    private var inactiveDepth = 0

    private static let entryProtocols: Set<String> = [
        "UIApplicationDelegate", "NSApplicationDelegate", "WKApplicationDelegate", "WKExtensionDelegate",
    ]

    init(file: String, converter: SourceLocationConverter, customLoggerNames: [String]) {
        self.file = file
        self.converter = converter
        self.loggerNames = Set(customLoggerNames)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Types

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.name.text, clause: node.inheritanceClause, attributes: node.attributes)
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.name.text, clause: node.inheritanceClause, attributes: node.attributes)
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.name.text, clause: node.inheritanceClause, attributes: node.attributes)
    }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.name.text, clause: node.inheritanceClause, attributes: node.attributes)
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.extendedType.trimmedDescription, clause: node.inheritanceClause, attributes: node.attributes)
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    private func enter(
        _ node: some SyntaxProtocol, name: String, clause: InheritanceClauseSyntax?, attributes: AttributeListSyntax
    ) -> SyntaxVisitorContinueKind {
        let inherited = (clause?.inheritedTypes ?? []).map { Self.baseName($0.type.trimmedDescription) }
        let attributeNames = attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
        let isApp = inherited.contains("App")
        typeStack.append(TypeScope(name: name, isApp: isApp))
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line

        if facts.entryPoint == nil {
            let hasMain = attributeNames.contains("main") && isApp
            let launchAttribute = attributeNames.contains { $0 == "UIApplicationMain" || $0 == "NSApplicationMain" }
            let delegate = inherited.first { Self.entryProtocols.contains($0) }
            if hasMain || launchAttribute || delegate != nil { facts.entryPoint = (file, line) }
        }
        for proto in inherited {
            if proto == "WKApplicationDelegate" || proto == "WKExtensionDelegate" { facts.entryHints.insert("watchOS") }
            if proto == "NSApplicationDelegate" { facts.entryHints.insert("macOS") }
        }
        if inherited.contains("MXMetricManagerSubscriber") {
            facts.subscribers.append(MetricKitSubscriberFact(name: name, active: inactiveDepth == 0, file: file, line: line))
        }
        return .visitChildren
    }

    private static func baseName(_ type: String) -> String {
        String(type.split(separator: ".").last ?? Substring(type))
    }

    // MARK: Functions

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let owner = typeStack.last
        let labels = node.signature.parameterClause.parameters.map { $0.firstName.text }
        let isLaunchHook = name == "applicationDidFinishLaunching" || name == "applicationWillFinishLaunching"
            || (name == "application" && labels.contains("didFinishLaunchingWithOptions"))
        facts.functions.append(MetricKitFunctionFact(
            name: name, owner: owner?.name, isInitializer: false, isStartRoot: isLaunchHook
        ))
        functionStack.append(facts.functions.count - 1)

        if name == "didReceive", let owner, let first = node.signature.parameterClause.parameters.first {
            let type = first.type.trimmedDescription
            let kind: MetricKitHandlerFact.Kind? = type.contains("MXMetricPayload") ? .metric
                : type.contains("MXDiagnosticPayload") ? .diagnostic : nil
            if let kind {
                let finder = PayloadPassOnFinder(loggerNames: loggerNames)
                if let body = node.body { finder.walk(body) }
                facts.handlers.append(MetricKitHandlerFact(
                    owner: owner.name, kind: kind, passesPayloadOn: finder.found, file: file,
                    line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line
                ))
            }
        }
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { functionStack.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let owner = typeStack.last
        facts.functions.append(MetricKitFunctionFact(
            name: "init", owner: owner?.name, isInitializer: true, isStartRoot: owner?.isApp == true
        ))
        functionStack.append(facts.functions.count - 1)
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { functionStack.removeLast() }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if let index = functionStack.last { facts.functions[index].referenced.insert(node.baseName.text) }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let index = functionStack.last, inactiveDepth == 0,
           node.calledExpression.trimmedDescription.replacingOccurrences(of: " ", with: "")
            .hasSuffix("MXMetricManager.shared.add") {
            facts.functions[index].registers = true
        }
        return .visitChildren
    }

    // MARK: Conditional compilation

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        var previousCanImport = false
        for clause in node.clauses {
            let condition = clause.condition?.trimmedDescription.replacingOccurrences(of: " ", with: "")
            let inactive: Bool
            switch condition {
            case "canImport(MetricKit)":
                inactive = false
                previousCanImport = true
            case "!canImport(MetricKit)":
                inactive = true
            case nil:
                inactive = previousCanImport
            default:
                inactive = false
            }
            if inactive { inactiveDepth += 1 }
            if let elements = clause.elements { walk(Syntax(elements)) }
            if inactive { inactiveDepth -= 1 }
        }
        return .skipChildren
    }
}

/// Decides whether a `didReceive` body does more with the payload than log it.
///
/// A body passes when it contains a call that is not a logging call, or an assignment. Calls
/// nested in a logging call's arguments are not counted, so `logger.info("\(p.jsonRepresentation())")`
/// is still only logging. Collection pass-throughs (`forEach`, `map`, ...) are looked through.
final class PayloadPassOnFinder: SyntaxVisitor {
    private(set) var found = false
    private let loggerNames: Set<String>

    private static let printLike: Set<String> = ["print", "debugPrint", "NSLog", "os_log", "dump", "Logger"]
    private static let logMethods: Set<String> = [
        "debug", "info", "notice", "warning", "error", "fault", "critical", "trace", "log",
    ]
    private static let transparent: Set<String> = ["forEach", "map", "compactMap", "flatMap", "filter", "enumerated"]

    init(loggerNames: Set<String>) {
        self.loggerNames = loggerNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if isLogging(node) { return .skipChildren }
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           Self.transparent.contains(member.declName.baseName.text) {
            return .visitChildren
        }
        found = true
        return .skipChildren
    }

    override func visit(_ node: AssignmentExprSyntax) -> SyntaxVisitorContinueKind {
        found = true
        return .skipChildren
    }

    override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if node.operator.text == "+=" { found = true }
        return .skipChildren
    }

    private func isLogging(_ call: FunctionCallExprSyntax) -> Bool {
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return Self.printLike.contains(ref.baseName.text) || loggerNames.contains(ref.baseName.text)
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        guard Self.logMethods.contains(member.declName.baseName.text) else { return false }
        let base = member.base?.trimmedDescription ?? ""
        return base.lowercased().contains("log") || loggerNames.contains { base.contains($0) }
    }
}
