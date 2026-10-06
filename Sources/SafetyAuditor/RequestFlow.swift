import ExternalInputSyntax
import Foundation
import QualityGateCore
import SwiftSyntax

/// What one file does with URL-shaped values: the per-file half of `security.ssrf`
/// (`AURLIsNotARequest.md` §3.1–3.3, §3.5).
///
/// Plain values, no syntax: the package-wide join in ``RequestFlowRules`` reads these after every
/// file has been walked, and no tree is kept alive for it.
struct RequestFlowFileFacts: Sendable {
    /// The file, as the caller named it.
    var file: String
    /// Each use of a value that has an origin.
    var flows: [RequestFlow] = []
    /// Each function parameter whose host the function asks about.
    var validators: [HostValidator] = []
}

/// A function's parameter, or a call's argument, by name: `fetch(url:)`, `send(_:)`.
struct RequestSlot: Sendable, Hashable {
    /// The function's name; an initialiser's is its type's.
    let function: String
    /// The argument label, or `_` and the position for an unlabelled one.
    let label: String

    /// `fetch(url:)`, `send(_:)`.
    var rendered: String {
        "\(function)(\(label.hasPrefix("_") ? "_" : label):)"
    }
}

/// Where the external-input model says a string came from, kept as text.
struct RequestInputSource: Sendable, Hashable {
    /// `HTTP request content`, `the command line` — `ExternalInput/Kind/phrase`.
    let phrase: String
    /// The accessor and the bindings it came through.
    let evidence: String
    /// Whether a remote party supplies it — `ExternalInput/Reach/network`.
    let isNetwork: Bool
}

/// Where a URL-shaped value came from, within one function (§3.2).
enum RequestOrigin: Sendable, Hashable {
    /// Constructed here from a string that is not a literal.
    case built(input: String, line: Int, column: Int, source: RequestInputSource?)
    /// Never constructed here, and traced to network-reachable external input.
    case external(RequestInputSource)
    /// A parameter of the enclosing function, received whole.
    case parameter(label: String)
    /// A stored property, or another name the function did not bind.
    case property(String)
    /// What a function of this package returned. Built or not is the join's to say: it knows
    /// which functions return a URL they built, and from which of their parameters.
    case result(function: String, signature: String, arguments: [RequestArgument], line: Int, column: Int)
}

/// An argument that is not a fixed literal, at a call whose result is used as a URL.
struct RequestArgument: Sendable, Hashable {
    /// The label, or `_` and the position.
    let label: String
    /// The argument as written, shortened.
    let text: String
}

/// What a function does with a value that has an origin (§3.3).
enum RequestUse: Sendable, Hashable {
    /// It is the operand of a call that opens a connection.
    case requested(sink: String)
    /// It is an argument of some other call.
    case passed(RequestSlot)
    /// It is assigned to, or appended into, a property of the enclosing type.
    case stored(property: String)
    /// It is what the enclosing function returns; `signature` is that function's labels.
    case returned(signature: String)
}

/// One use of one value.
struct RequestFlow: Sendable, Hashable {
    /// The enclosing function's name — its type's, for an initialiser. `nil` in an accessor,
    /// a stored closure or top-level code.
    let function: String?
    /// The enclosing type, or extended type.
    let enclosingType: String?
    let origin: RequestOrigin
    let use: RequestUse
    /// Where the use is.
    let line: Int
    let column: Int
    /// A host question was asked about the value before the use, in this function (§3.5).
    let hostAsked: Bool
    /// Functions the value was handed to, in a condition or a `try` statement, before the use.
    /// Validation only if the join finds one of them to be a host validator.
    let checkedBy: [RequestSlot]
    /// For a *built* URL that is *returned*: the parameter its string came from, if it was one.
    /// Then whether the URL is dynamic is each caller's argument to say.
    let inputParameter: String?
}

/// A parameter whose host its function asks about, directly or by handing it on.
struct HostValidator: Sendable, Hashable {
    let slot: RequestSlot
    /// The body asks a host question about the parameter.
    let asksDirectly: Bool
    /// The body hands the parameter to these, in a condition or a `try` statement.
    let handsTo: [RequestSlot]
}

// MARK: - Collecting

/// Reads a file's ``RequestFlowFileFacts`` off its tree.
final class RequestFlowCollector: SyntaxVisitor {

    /// Collects the facts of one parsed file.
    static func collect(
        from tree: SourceFileSyntax,
        converter: SourceLocationConverter,
        fileName: String
    ) -> RequestFlowFileFacts {
        let collector = RequestFlowCollector(tree: tree, converter: converter)
        collector.walk(tree)
        var seen: Set<RequestFlow> = []
        let flows = collector.flows.filter { seen.insert($0).inserted }
        return RequestFlowFileFacts(file: fileName, flows: flows, validators: collector.validators)
    }

    private let converter: SourceLocationConverter
    private let externalInput: ExternalInputFile
    /// Same-file `let` string constants and, where a name has one value, that value.
    private let localStringConstants: [String: String?]
    private var regions: [SyntaxIdentifier: Region] = [:]
    private var flows: [RequestFlow] = []
    private var validators: [HostValidator] = []

    private init(tree: SourceFileSyntax, converter: SourceLocationConverter) {
        self.converter = converter
        self.externalInput = ExternalInputFile(tree)
        let constants = ConstantValueReader(viewMode: .sourceAccurate)
        constants.walk(tree)
        self.localStringConstants = constants.values
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Vocabulary

    /// `URLSession` methods that send a request for their first argument.
    static let sessionMethods: Set<String> = [
        "data", "bytes", "download", "upload", "dataTask", "downloadTask", "uploadTask", "webSocketTask",
    ]
    static let sessionLabels: Set<String> = ["from", "for", "with"]
    /// Types whose `contentsOf:` initialiser loads what a URL names.
    static let contentsOfTypes: Set<String> = [
        "Data", "NSData", "String", "NSString", "XMLParser", "NSDictionary", "NSArray",
    ]
    /// Initialisers that are part of how a URL is resolved, and so are not "some other call".
    static let constructors: Set<String> = [
        "URL", "NSURL", "URLRequest", "NSMutableURLRequest", "URLComponents", "HTTPClientRequest", "URI",
    ]
    /// `URL(…)` labels that make a file URL — never a network address.
    static let fileLabels: Set<String> = [
        "fileURLWithPath", "filePath", "fileURLWithFileSystemRepresentation", "fileReferenceLiteralResourceName",
    ]
    /// Properties that are still the URL they are read from: `request.url`, `u.absoluteString`.
    static let hostPreservingMembers: Set<String> = [
        "absoluteURL", "absoluteString", "standardized", "standardizedFileURL", "url", "mainDocumentURL",
    ]
    /// Methods that change a URL's path or query and leave its host whose it was.
    static let hostPreservingMethods: Set<String> = [
        "appendingPathComponent", "appendingPathExtension", "appending", "deletingLastPathComponent",
        "deletingPathExtension", "resolvingSymlinksInPath",
    ]
    /// Collection methods whose result holds the same elements.
    static let elementPreserving: Set<String> = [
        "filter", "prefix", "suffix", "sorted", "reversed", "shuffled", "dropFirst", "dropLast",
        "first", "last", "randomElement", "lazy", "uniqued",
    ]
    static let mapping: Set<String> = ["map", "compactMap", "flatMap"]
    /// Collection initialisers that copy their one unlabelled argument.
    static let collectionCopies: Set<String> = ["Array", "Set", "ContiguousArray"]
    /// String methods whose result is still the host they were called on.
    static let hostTransforms: Set<String> = ["lowercased", "uppercased", "trimmingCharacters"]
    /// Methods that compare the value they are called on, or given, with something.
    static let comparisons: Set<String> = [
        "contains", "hasSuffix", "hasPrefix", "caseInsensitiveCompare", "elementsEqual", "compare",
    ]

    // MARK: Regions

    /// One function: its bindings, its labelled parameters, and — on first use — its host questions.
    private final class Region {
        let body: Syntax
        let bindings: FunctionBindings
        let function: String?
        /// The type, or extended type, the function is declared in.
        let typeName: String?
        let parameters: [(label: String, name: String, type: String)]
        /// Whether the function is a `func` — the only kind whose result a caller can name.
        let returnsToCaller: Bool
        var hostFacts: HostFacts?

        init(body: Syntax, bindings: FunctionBindings, function: String?, typeName: String?,
             parameters: [(label: String, name: String, type: String)], returnsToCaller: Bool) {
            self.body = body
            self.bindings = bindings
            self.function = function
            self.typeName = typeName
            self.parameters = parameters
            self.returnsToCaller = returnsToCaller
        }

        /// The function's labels as a call writes them: `_:to:`.
        var signature: String {
            parameters.map { ($0.label.hasPrefix("_") ? "_" : $0.label) + ":" }.joined()
        }
    }

    private func region(of node: some SyntaxProtocol) -> Region {
        let body = ExternalInputFile.functionBody(of: node)
        if let known = regions[body.id] { return known }
        let function = ExternalInputFile.enclosingFunction(of: node)
        let typeName = ExternalInputFile.enclosingType(of: body)
        var name: String?
        var list: FunctionParameterListSyntax?
        if let declaration = function?.as(FunctionDeclSyntax.self) {
            name = declaration.name.text
            list = declaration.signature.parameterClause.parameters
        } else if let declaration = function?.as(InitializerDeclSyntax.self) {
            name = typeName
            list = declaration.signature.parameterClause.parameters
        }
        let parameters = (list.map(Array.init) ?? []).enumerated().map { index, parameter in
            (label: parameter.firstName.text == "_" ? "_\(index)" : parameter.firstName.text,
             name: (parameter.secondName ?? parameter.firstName).text,
             type: parameter.type.trimmedDescription)
        }
        let made = Region(
            body: body, bindings: ExternalInputFile.bindingSites(at: node),
            function: name, typeName: typeName, parameters: parameters,
            returnsToCaller: function?.is(FunctionDeclSyntax.self) == true)
        regions[body.id] = made
        return made
    }

    // MARK: Visiting

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let region = region(of: node)
        if let sink = sink(node, in: region) {
            record(sink.resolved, use: .requested(sink: sink.name), at: node, in: region)
        } else {
            recordStoreByMutation(node, in: region)
            recordPassed(node, in: region)
        }
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self) else { return .visitChildren }
        let region = region(of: node)
        guard let property = propertyName(elements[0], at: node, in: region),
              let resolved = resolve(elements[2], from: Syntax(node), in: region), resolved.isWorthStoring else {
            return .visitChildren
        }
        record(resolved, use: .stored(property: property), at: node, in: region)
        return .visitChildren
    }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if let value = node.expression {
            recordReturned(value, at: node)
        }
        return .visitChildren
    }

    /// `value` leaves its function: a fact only when it is a URL built here, or one some other
    /// function returned, and the function is one a caller can name.
    private func recordReturned(_ value: ExprSyntax, at node: some SyntaxProtocol) {
        // A `return` inside a closure returns from the closure, not from the function.
        var cursor = node.parent
        while let current = cursor, !ExternalInputFile.isFunctionDeclaration(current) {
            if current.is(ClosureExprSyntax.self) { return }
            cursor = current.parent
        }
        let region = region(of: node)
        guard region.returnsToCaller, region.function != nil,
              let resolved = resolve(value, from: Syntax(node), in: region), resolved.isProduced else { return }
        record(resolved, use: .returned(signature: region.signature), at: node, in: region)
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        guard let body = node.body else { return }
        // A body that is one expression returns it.
        if body.statements.count == 1, let only = body.statements.first, case .expr(let value) = only.item {
            recordReturned(value, at: only)
        }
        let region = region(of: body)
        guard let function = region.function, !region.parameters.isEmpty else { return }
        let facts = hostFacts(of: region)
        for parameter in region.parameters {
            let asks = facts.questions.contains { $0.root == parameter.name }
            let hands = facts.checks.filter { $0.root == parameter.name }.map(\.slot)
            guard asks || !hands.isEmpty else { continue }
            validators.append(HostValidator(
                slot: RequestSlot(function: function, label: parameter.label),
                asksDirectly: asks, handsTo: hands))
        }
    }

    // MARK: Uses

    /// The sink `call` is, and what its operand resolves to.
    private func sink(_ call: FunctionCallExprSyntax, in region: Region) -> (name: String, resolved: Resolved)? {
        guard let first = call.arguments.first else { return nil }
        let point = Syntax(call)
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let type = reference.baseName.text
            if Self.contentsOfTypes.contains(type), first.label?.text == "contentsOf" {
                return operand(first.expression, of: "\(type)(contentsOf:)", from: point, in: region)
            }
            if type == "NWConnection", first.label?.text == "to" {
                return operand(first.expression, of: "NWConnection(to:)", from: point, in: region)
            }
            return nil
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let method = member.declName.baseName.text
        if Self.sessionMethods.contains(method), let label = first.label?.text, Self.sessionLabels.contains(label) {
            return operand(first.expression, of: "\(method)(\(label):)", from: point, in: region)
        }
        if method == "connect", first.label?.text == "to", member.base?.trimmedDescription == "WebSocket" {
            return operand(first.expression, of: "WebSocket.connect(to:)", from: point, in: region)
        }
        // `execute` and `load` are ordinary words: sinks only through the request they are given.
        if method == "execute" || method == "load", first.label == nil,
           let resolved = resolve(first.expression, from: point, in: region) {
            if method == "execute", resolved.viaClientRequest { return ("execute(_:)", resolved) }
            if method == "load", resolved.viaURLRequest { return ("load(_:)", resolved) }
        }
        return nil
    }

    /// A sink's operand resolved — or, where it has no origin here, traced to the network.
    private func operand(
        _ expression: ExprSyntax, of name: String, from point: Syntax, in region: Region
    ) -> (name: String, resolved: Resolved)? {
        var inert = false
        if let resolved = resolve(expression, from: point, in: region, inert: &inert) {
            return (name, resolved)
        }
        // A URL that was never built here — a decoded property of a request body — is a request
        // to an address a remote party chose (§3.6). Not asked of a literal or a file URL.
        guard !inert, let trace = externalInput.trace(of: expression), trace.kind.reach == .network else {
            return nil
        }
        return (name, Resolved(origin: .external(Self.source(trace)), names: Self.rootName(of: expression).map { [$0] } ?? []))
    }

    /// `call`'s arguments that have an origin, each as *passed to (callee, label)*.
    private func recordPassed(_ call: FunctionCallExprSyntax, in region: Region) {
        guard !call.arguments.isEmpty, let callee = Self.calleeName(of: call, in: region.typeName),
              !Self.constructors.contains(callee) else { return }
        for (index, argument) in call.arguments.enumerated() {
            guard let resolved = resolve(argument.expression, from: Syntax(call), in: region) else { continue }
            let slot = RequestSlot(function: callee, label: argument.label?.text ?? "_\(index)")
            record(resolved, use: .passed(slot), at: call, in: region)
        }
    }

    /// `urls.append(u)` / `urls.insert(u)` on a property: stored there.
    private func recordStoreByMutation(_ call: FunctionCallExprSyntax, in region: Region) {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              ["append", "insert"].contains(member.declName.baseName.text),
              let base = member.base, let first = call.arguments.first,
              let property = propertyName(base, at: call, in: region),
              let resolved = resolve(first.expression, from: Syntax(call), in: region), resolved.isWorthStoring else {
            return
        }
        record(resolved, use: .stored(property: property), at: call, in: region)
    }

    /// The property `target` names — `self.p`, or a bare `p` this function did not bind.
    private func propertyName(_ target: ExprSyntax, at node: some SyntaxProtocol, in region: Region) -> String? {
        if let member = target.as(MemberAccessExprSyntax.self) {
            guard member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" else { return nil }
            return member.declName.baseName.text
        }
        guard let name = target.as(DeclReferenceExprSyntax.self)?.baseName.text,
              region.bindings.binding(of: name, before: node) == nil,
              !region.parameters.contains(where: { $0.name == name }),
              !Self.closureParameters(around: Syntax(node)).contains(name) else { return nil }
        return name
    }

    private func record(_ resolved: Resolved, use: RequestUse, at node: some SyntaxProtocol, in region: Region) {
        let facts = hostFacts(of: region)
        let names = Set(resolved.names)
        let location = node.startLocation(converter: converter)
        flows.append(RequestFlow(
            function: region.function, enclosingType: region.typeName, origin: resolved.origin, use: use,
            line: location.line, column: location.column,
            hostAsked: facts.questions.contains { names.contains($0.root) && $0.position < node.position },
            checkedBy: facts.checks.filter { names.contains($0.root) && $0.position < node.position }.map(\.slot),
            inputParameter: resolved.inputRoot.flatMap { root in region.parameters.first { $0.name == root }?.label }))
    }

    /// The name a call is made by: `fetch`, `MJPEGStream`; `Self(…)` and `self.init(…)` are the enclosing type.
    private static func calleeName(of call: FunctionCallExprSyntax, in typeName: String?) -> String? {
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            return name == "Self" ? typeName : name
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let name = member.declName.baseName.text
        guard name == "init" else { return name }
        guard let base = member.base else { return nil }
        if let reference = base.as(DeclReferenceExprSyntax.self) {
            return ["self", "Self"].contains(reference.baseName.text) ? typeName : reference.baseName.text
        }
        return base.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    // MARK: Origins

    /// A value with an origin, and how it was reached.
    struct Resolved {
        var origin: RequestOrigin
        /// Every name the value went by on the way: bindings, the parameter, the property.
        var names: [String]
        var viaURLRequest = false
        var viaClientRequest = false
        /// For a *built* URL: the leftmost name of the string it was built from.
        var inputRoot: String?

        /// Built here, or returned by something that may have built it.
        var isProduced: Bool {
            switch origin {
            case .built, .result: return true
            case .external, .parameter, .property: return false
            }
        }

        /// Storing a property in a property moves nothing the join needs to know about.
        var isWorthStoring: Bool {
            if case .property = origin { return false }
            return true
        }
    }

    private func resolve(_ expression: ExprSyntax, from point: Syntax, in region: Region) -> Resolved? {
        var inert = false
        return resolve(expression, from: point, in: region, inert: &inert)
    }

    /// Resolves `expression` and says, when it has no origin, whether that is because it is
    /// known to be harmless — a literal, a file URL — rather than merely unknown.
    private func resolve(
        _ expression: ExprSyntax, from point: Syntax, in region: Region, inert: inout Bool
    ) -> Resolved? {
        let closureParameters = Self.closureParameters(around: point)
        return resolve(expression, at: point, in: region, closureParameters: closureParameters, depth: 0, inert: &inert)
    }

    // The walk is bounded: every step either strips a wrapper, follows a binding to an earlier
    // one, or descends into an operand, and `depth` stops a pathological chain.
    private func resolve(
        _ expression: ExprSyntax, at point: Syntax, in region: Region,
        closureParameters: Set<String>, depth: Int, inert: inout Bool
    ) -> Resolved? {
        guard depth < 24 else { return nil }
        let value = Self.unwrapped(expression)
        func deeper(_ next: ExprSyntax, at nextPoint: Syntax? = nil, inert: inout Bool) -> Resolved? {
            resolve(next, at: nextPoint ?? point, in: region, closureParameters: closureParameters,
                    depth: depth + 1, inert: &inert)
        }

        if value.is(StringLiteralExprSyntax.self) || value.is(NilLiteralExprSyntax.self) {
            inert = true
            return nil
        }
        if let reference = value.as(DeclReferenceExprSyntax.self) {
            return resolveName(reference.baseName.text, at: point, in: region, closureParameters: closureParameters) {
                deeper($0, at: Syntax($0), inert: &inert)
            }
        }
        if let member = value.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return nil }
            let name = member.declName.baseName.text
            if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
                return Resolved(origin: .property(name), names: [name])
            }
            return Self.hostPreservingMembers.contains(name) ? deeper(base, inert: &inert) : nil
        }
        if let call = value.as(FunctionCallExprSyntax.self) {
            return resolveCall(call, at: point, in: region, inert: &inert) { deeper($0, inert: &$1) }
        }
        if let subscripted = value.as(SubscriptCallExprSyntax.self) {
            return deeper(subscripted.calledExpression, inert: &inert)
        }
        if let ternary = value.as(TernaryExprSyntax.self) {
            return deeper(ternary.thenExpression, inert: &inert) ?? deeper(ternary.elseExpression, inert: &inert)
        }
        if let sequence = value.as(SequenceExprSyntax.self) {
            // `a ?? b`, `c ? a : b`: the first operand that has an origin.
            for element in sequence.elements {
                if let ternary = element.as(UnresolvedTernaryExprSyntax.self) {
                    if let found = deeper(ternary.thenExpression, inert: &inert) { return found }
                    continue
                }
                if element.is(BinaryOperatorExprSyntax.self) { continue }
                if let found = deeper(element, inert: &inert) { return found }
            }
        }
        return nil
    }

    private func resolveName(
        _ name: String, at point: Syntax, in region: Region, closureParameters: Set<String>,
        following: (ExprSyntax) -> Resolved?
    ) -> Resolved? {
        if let binding = region.bindings.binding(of: name, before: point) {
            guard var found = following(binding.value) else { return nil }
            found.names.append(name)
            return found
        }
        if let parameter = region.parameters.first(where: { $0.name == name }) {
            // Only a parameter that can hold an address: a `String` built into a URL is reported
            // where it is built, and every other parameter is not this rule's business.
            guard parameter.type.contains("URL") || parameter.type.contains("HTTPClientRequest")
                    || parameter.type.contains("URI") else { return nil }
            var found = Resolved(origin: .parameter(label: parameter.label), names: [name])
            found.viaURLRequest = parameter.type.contains("URLRequest")
            found.viaClientRequest = parameter.type.contains("HTTPClientRequest")
            return found
        }
        // A closure's own parameter, a type, `self`: no origin. Anything else the function did
        // not bind is a property (or a global, which the join treats as one with no type).
        guard !closureParameters.contains(name), !name.hasPrefix("$"), name != "self", name != "super",
              name.first?.isLowercase == true else { return nil }
        return Resolved(origin: .property(name), names: [name])
    }

    private func resolveCall(
        _ call: FunctionCallExprSyntax, at point: Syntax, in region: Region, inert: inout Bool,
        deeper: (ExprSyntax, inout Bool) -> Resolved?
    ) -> Resolved? {
        func argument(_ label: String) -> ExprSyntax? {
            call.arguments.first { $0.label?.text == label }?.expression
        }
        if let type = Self.constructedType(call) {
            switch type {
            case "URL", "NSURL":
                if call.arguments.contains(where: { Self.fileLabels.contains($0.label?.text ?? "") }) {
                    inert = true
                    return nil
                }
                guard let string = argument("string") else { return nil }
                return built(from: string, at: call, point: point, in: region, inert: &inert, deeper: deeper)
            case "URLComponents":
                if let string = argument("string") { return built(from: string, at: call, point: point, in: region, inert: &inert, deeper: deeper) }
                return argument("url").flatMap { deeper($0, &inert) }
            case "URLRequest", "NSMutableURLRequest":
                guard var found = argument("url").flatMap({ deeper($0, &inert) }) else { return nil }
                found.viaURLRequest = true
                return found
            case "HTTPClientRequest":
                guard var found = argument("url").flatMap({ built(from: $0, at: call, point: point, in: region, inert: &inert, deeper: deeper) }) else {
                    return nil
                }
                found.viaClientRequest = true
                return found
            case "URI":
                return argument("string").flatMap { built(from: $0, at: call, point: point, in: region, inert: &inert, deeper: deeper) }
            default:
                return nil
            }
        }
        // `Array(urls.prefix(3))`, `Set(urls)`: a copy holds what it was copied from.
        if let type = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           Self.collectionCopies.contains(type), call.arguments.count == 1,
           let only = call.arguments.first, only.label == nil {
            return deeper(only.expression, &inert)
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else {
            return producedResult(call)
        }
        let method = member.declName.baseName.text
        // `.url(u)` — `NWEndpoint.url`, as an argument of `NWConnection(to:)`.
        if method == "url", call.arguments.count == 1, let only = call.arguments.first, only.label == nil,
           member.base == nil || member.base?.trimmedDescription == "NWEndpoint" {
            return deeper(only.expression, &inert)
        }
        guard let base = member.base else { return nil }
        if Self.mapping.contains(method), let closure = Self.closure(of: call),
           let construction = DynamicConstructionFinder.first(in: closure, using: self) {
            return construction
        }
        if Self.hostPreservingMethods.contains(method) || Self.elementPreserving.contains(method)
            || Self.mapping.contains(method) {
            return deeper(base, &inert)
        }
        return producedResult(call)
    }

    /// `URL` for `URL(…)`, `URL.init(…)`; `nil` for anything that is not one of ``constructors``.
    private static func constructedType(_ call: FunctionCallExprSyntax) -> String? {
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return constructors.contains(reference.baseName.text) ? reference.baseName.text : nil
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init",
           let type = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text, constructors.contains(type) {
            return type
        }
        return nil
    }

    private static func closure(of call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
        call.trailingClosure ?? call.arguments.lazy.compactMap { $0.expression.as(ClosureExprSyntax.self) }.first
    }

    /// A URL made from `string`: *built* unless the string is a literal, fixes its own host, or
    /// is another URL's `absoluteString`.
    private func built(
        from string: ExprSyntax, at construction: FunctionCallExprSyntax, point: Syntax, in region: Region,
        inert: inout Bool, deeper: (ExprSyntax, inout Bool) -> Resolved?
    ) -> Resolved? {
        let value = Self.unwrapped(string)
        // `"\(base.absoluteString)/v1/x"` is `base` with a longer path: the host is base's.
        if let base = urlExtended(by: value, at: point, in: region) {
            return deeper(base, &inert)
        }
        if let literal = value.as(StringLiteralExprSyntax.self), isFixed(literal) {
            inert = true
            return nil
        }
        if let sequence = value.as(SequenceExprSyntax.self), concatenationFixesHost(sequence) {
            inert = true
            return nil
        }
        // Re-parsing a URL builds nothing: it is the URL it was.
        if let member = value.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "absoluteString",
           let base = member.base {
            return deeper(base, &inert)
        }
        return constructed(from: string, at: construction)
    }

    /// The URL a string extends: it begins with that URL's `absoluteString` — directly, through a
    /// binding, or as `u.absoluteString ?? "https://constant"` — and what follows starts a path.
    ///
    /// Without the separator the string is not an extension: `"\(u.absoluteString)\(suffix)"`
    /// can turn `https://a.example` into `https://a.example.evil.test`.
    private func urlExtended(by string: ExprSyntax, at point: Syntax, in region: Region) -> ExprSyntax? {
        // The first piece and whether the second starts a path — all this needs of the string.
        var first: ExprSyntax?
        var secondStartsPath: Bool?
        func take(text: String) {
            // An empty run of text between two holes is no piece at all.
            guard !text.isEmpty, secondStartsPath == nil else { return }
            secondStartsPath = first != nil && text.first.map { "/?#".contains($0) } == true
        }
        func take(_ expression: ExprSyntax) {
            guard secondStartsPath == nil else { return }
            if first == nil {
                first = expression
            } else {
                secondStartsPath = startsPath(expression, at: point, in: region, depth: 0)
            }
        }
        if let literal = string.as(StringLiteralExprSyntax.self) {
            for segment in literal.segments {
                if let text = segment.as(StringSegmentSyntax.self) {
                    take(text: text.content.text)
                } else if let hole = segment.as(ExpressionSegmentSyntax.self), hole.expressions.count == 1,
                          let only = hole.expressions.first {
                    take(only.expression)
                } else {
                    return nil
                }
            }
        } else if let sequence = string.as(SequenceExprSyntax.self) {
            for (index, element) in sequence.elements.enumerated() {
                if index % 2 == 1 {
                    guard element.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" else { return nil }
                } else {
                    take(element)
                }
            }
        }
        guard let first, secondStartsPath == true else { return nil }
        return absoluteStringBase(first, at: point, in: region, depth: 0)
    }

    /// `u` for `u.absoluteString`, for a name bound to it, and for `u.absoluteString ?? constant`
    /// where the constant is a same-file string that names a whole host itself.
    private func absoluteStringBase(_ expression: ExprSyntax, at point: Syntax, in region: Region, depth: Int) -> ExprSyntax? {
        guard depth < 8 else { return nil }
        let value = Self.unwrapped(expression)
        if let member = value.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "absoluteString" {
            return member.base
        }
        if let name = value.as(DeclReferenceExprSyntax.self)?.baseName.text,
           let binding = region.bindings.binding(of: name, before: point), !binding.isIteration {
            return absoluteStringBase(binding.value, at: Syntax(binding.value), in: region, depth: depth + 1)
        }
        guard let sequence = value.as(SequenceExprSyntax.self) else { return nil }
        var base: ExprSyntax?
        for (index, element) in sequence.elements.enumerated() {
            if index % 2 == 1 {
                guard element.as(BinaryOperatorExprSyntax.self)?.operator.text == "??" else { return nil }
            } else if let found = absoluteStringBase(element, at: point, in: region, depth: depth + 1) {
                base = base ?? found
            } else {
                // Every alternative must be an address already: a constant that names its host.
                let text: String?
                if let literal = element.as(StringLiteralExprSyntax.self) {
                    text = Self.plainText(of: literal)
                } else {
                    text = Self.constantName(of: element).flatMap { name in localStringConstants[name].flatMap { $0 } }
                }
                guard let text, Self.namesWholeHost(text + "/") else { return nil }
            }
        }
        return base
    }

    /// Whether a piece of a string starts a path, a query or a fragment: a literal beginning
    /// `/`, `?` or `#`, a name bound to one, or `p.hasPrefix("/") ? p : "/\(p)"`.
    private func startsPath(_ expression: ExprSyntax, at point: Syntax, in region: Region, depth: Int) -> Bool {
        guard depth < 8 else { return false }
        let value = Self.unwrapped(expression)
        if let literal = value.as(StringLiteralExprSyntax.self) {
            guard let first = literal.segments.first?.as(StringSegmentSyntax.self)?.content.text.first else { return false }
            return "/?#".contains(first)
        }
        if let name = value.as(DeclReferenceExprSyntax.self)?.baseName.text,
           let binding = region.bindings.binding(of: name, before: point), !binding.isIteration {
            return startsPath(binding.value, at: Syntax(binding.value), in: region, depth: depth + 1)
        }
        // `c ? a : b`, unfolded: [c, ? a :, b].
        let elements = value.as(SequenceExprSyntax.self).map { Array($0.elements) } ?? []
        guard elements.count == 3, let ternary = elements[1].as(UnresolvedTernaryExprSyntax.self) else { return false }
        let then = ternary.thenExpression.trimmedDescription
        let asked = elements[0].trimmedDescription.filter { !$0.isWhitespace } == "\(then).hasPrefix(\"/\")"
        return (asked || startsPath(ternary.thenExpression, at: point, in: region, depth: depth + 1))
            && startsPath(elements[2], at: point, in: region, depth: depth + 1)
    }

    /// The *built* origin for a construction whose string is already known to be dynamic.
    func constructed(from string: ExprSyntax, at construction: FunctionCallExprSyntax) -> Resolved {
        let location = construction.startLocation(converter: converter)
        let source = externalInput.trace(of: string).map(Self.source)
        var made = Resolved(
            origin: .built(input: Self.shortened(string), line: location.line, column: location.column, source: source),
            names: [])
        made.inputRoot = Self.rootName(of: string)
        return made
    }

    /// The result of a call to a function this package may declare: `parsed(text)`,
    /// `Self.endpoint(for: id)`, `Server.url()`. A method on some other value is not followed —
    /// its receiver has no name to join on.
    private func producedResult(_ call: FunctionCallExprSyntax) -> Resolved? {
        let name: String
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            name = reference.baseName.text
        } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
                  base == "self" || base.first?.isUppercase == true {
            name = member.declName.baseName.text
        } else {
            return nil
        }
        guard name.first?.isLowercase == true, name != "init" else { return nil }
        var dynamic: [RequestArgument] = []
        for (index, argument) in call.arguments.enumerated() where dynamic.count < 4 {
            let value = Self.unwrapped(argument.expression)
            if let literal = value.as(StringLiteralExprSyntax.self), isFixed(literal) { continue }
            if value.is(IntegerLiteralExprSyntax.self) || value.is(FloatLiteralExprSyntax.self)
                || value.is(BooleanLiteralExprSyntax.self) || value.is(NilLiteralExprSyntax.self) { continue }
            dynamic.append(RequestArgument(
                label: argument.label?.text ?? "_\(index)", text: Self.shortened(argument.expression)))
        }
        let location = call.startLocation(converter: converter)
        return Resolved(
            origin: .result(
                function: name, signature: call.arguments.map { ($0.label?.text ?? "_") + ":" }.joined(),
                arguments: dynamic, line: location.line, column: location.column),
            names: [])
    }

    /// Whether a `URL(string:)`-shaped call is built from non-literal input — for a closure body.
    func dynamicConstruction(_ call: FunctionCallExprSyntax) -> Resolved? {
        guard let type = Self.constructedType(call), ["URL", "NSURL", "URLComponents", "URI"].contains(type),
              let string = call.arguments.first(where: { $0.label?.text == "string" })?.expression else { return nil }
        let value = Self.unwrapped(string)
        if let literal = value.as(StringLiteralExprSyntax.self), isFixed(literal) { return nil }
        return constructed(from: string, at: call)
    }

    /// A literal with no dynamic input in it, or none that can move the host.
    ///
    /// Plain; or every interpolation a string constant declared in this file; or scheme and host
    /// written out — in the literal's own text or in such a constant — before the first
    /// interpolation that is not one.
    private func isFixed(_ literal: StringLiteralExprSyntax) -> Bool {
        var prefix = ""
        var rest = ""
        var sawInput = false
        for segment in literal.segments {
            if let text = segment.as(StringSegmentSyntax.self)?.content.text {
                if sawInput { rest += text } else { prefix += text }
            } else if let hole = segment.as(ExpressionSegmentSyntax.self) {
                if !sawInput, hole.expressions.count == 1, let only = hole.expressions.first,
                   let name = Self.constantName(of: only.expression), let constant = localStringConstants[name] {
                    // A name declared twice with different text is still a constant; which text
                    // is unknown, so it stands in as an opaque piece of a host.
                    prefix += constant ?? "x"
                } else {
                    sawInput = true
                }
            }
        }
        return !sawInput || Self.fixesHost(prefix: prefix, rest: rest)
    }

    /// `"https://api.example.com/" + path`, `Self.baseURL + "/v1/" + id`: the leading literals and
    /// same-file constants of a `+` chain, read as ``isFixed(_:)`` reads a literal's prefix.
    private func concatenationFixesHost(_ sequence: SequenceExprSyntax) -> Bool {
        var prefix = ""
        for (index, element) in sequence.elements.enumerated() {
            if index % 2 == 1 {
                guard element.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" else { return false }
            } else if let literal = element.as(StringLiteralExprSyntax.self), let text = Self.plainText(of: literal) {
                prefix += text
            } else if let name = Self.constantName(of: element), let constant = localStringConstants[name] {
                prefix += constant ?? "x"
            } else {
                break
            }
        }
        return Self.fixesHost(prefix: prefix, rest: "")
    }

    /// The identifier an expression names, if it is a bare reference or a one-step member access.
    static func constantName(of expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
           base.is(DeclReferenceExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }

    /// The text of a literal with no interpolation.
    private static func plainText(of literal: StringLiteralExprSyntax) -> String? {
        guard !literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else { return nil }
        return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
    }

    /// `scheme://host` followed by `/`, `?` or `#`: whatever is appended cannot change the host.
    static func namesWholeHost(_ text: String) -> Bool {
        guard let separator = text.range(of: "://"), separator.lowerBound > text.startIndex,
              text[..<separator.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else {
            return false
        }
        let authority = text[separator.upperBound...]
        guard let end = authority.firstIndex(where: { "/?#".contains($0) }) else { return false }
        return end > authority.startIndex
    }

    /// Whether the text before a string's first dynamic piece writes out its scheme and host —
    /// `"https://api.example.com/users/\(id)"`, `"ws://127.0.0.1:\(port)/"`.
    ///
    /// A host cut off by the dynamic piece (`"https://api.example.com\(suffix)"`) is not fixed.
    /// A `:` before it is a port only if no `@` follows; otherwise it is a password.
    static func fixesHost(prefix: String, rest: String) -> Bool {
        if namesWholeHost(prefix) { return true }
        guard prefix.hasSuffix(":"), let separator = prefix.range(of: "://") else { return false }
        let host = prefix[separator.upperBound...].dropLast()
        return !host.isEmpty && !host.contains("@") && !rest.contains("@") && namesWholeHost(prefix + "0/")
    }

    // MARK: Small readings

    /// `expression` without `try`, `await`, `?`, `!`, parentheses, a cast, or `#require(…)`.
    static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
        var current = expression
        // Bounded: nobody nests wrappers this deep.
        for _ in 0..<16 {
            if let inner = ExternalInputFile.transparentInner(current) {
                current = inner
            } else if let macro = current.as(MacroExpansionExprSyntax.self), macro.macroName.text == "require",
                      let first = macro.arguments.first {
                current = first.expression
            } else {
                break
            }
        }
        return current
    }

    /// The leftmost name of a member chain — `request` in `request.url?.host`, `url` in `self.url.host`.
    static func rootName(of expression: ExprSyntax) -> String? {
        var current = unwrapped(expression)
        for _ in 0..<16 {
            if let reference = current.as(DeclReferenceExprSyntax.self) {
                return reference.baseName.text
            }
            if let member = current.as(MemberAccessExprSyntax.self), let base = member.base {
                if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" { return member.declName.baseName.text }
                current = unwrapped(base)
            } else if let call = current.as(FunctionCallExprSyntax.self),
                      let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base {
                current = unwrapped(base)
            } else {
                return nil
            }
        }
        return nil
    }

    /// The parameter names of every closure between `node` and its function.
    static func closureParameters(around node: Syntax) -> Set<String> {
        var names: Set<String> = []
        var cursor = node.parent
        while let current = cursor {
            if ExternalInputFile.isFunctionDeclaration(current) { break }
            if let closure = current.as(ClosureExprSyntax.self) {
                switch closure.signature?.parameterClause {
                case .simpleInput(let list)?:
                    names.formUnion(list.map(\.name.text))
                case .parameterClause(let clause)?:
                    names.formUnion(clause.parameters.map { ($0.secondName ?? $0.firstName).text })
                case nil:
                    break
                }
            }
            cursor = current.parent
        }
        return names
    }

    private static func shortened(_ expression: ExprSyntax) -> String {
        let text = expression.trimmedDescription.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count > 60 ? String(text.prefix(57)) + "…" : text
    }

    private static func source(_ trace: ExternalInput.Trace) -> RequestInputSource {
        RequestInputSource(
            phrase: trace.kind.phrase, evidence: SecurityVisitor.describe(trace),
            isNetwork: trace.kind.reach == .network)
    }

    // MARK: Host questions

    private func hostFacts(of region: Region) -> HostFacts {
        if let known = region.hostFacts { return known }
        var aliases: [String: String] = [:]
        for site in region.bindings.sites where !site.isIteration {
            if let root = Self.hostRoot(of: site.value) { aliases[site.name] = root }
        }
        let typeName = region.typeName
        let reader = HostQuestionReader(aliases: aliases, body: region.body.id) { call in
            Self.calleeName(of: call, in: typeName)
        }
        reader.walk(region.body)
        let facts = HostFacts(questions: reader.questions, checks: reader.checks)
        region.hostFacts = facts
        return facts
    }

    /// The URL whose host `value` is — `url` for `url.host?.lowercased()`.
    static func hostRoot(of value: ExprSyntax) -> String? {
        var current = unwrapped(value)
        for _ in 0..<8 {
            if let call = current.as(FunctionCallExprSyntax.self),
               let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base {
                if member.declName.baseName.text == "host" { return rootName(of: base) }
                guard hostTransforms.contains(member.declName.baseName.text) else { return nil }
                current = unwrapped(base)
            } else if let member = current.as(MemberAccessExprSyntax.self), let base = member.base {
                return member.declName.baseName.text == "host" ? rootName(of: base) : nil
            } else {
                return nil
            }
        }
        return nil
    }
}
