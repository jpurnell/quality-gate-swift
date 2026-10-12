import Foundation

/// The gate's one definition of "this value came from outside the program"
/// (`TheGateIsNotYetAggressive.md` §2.2 item 3).
///
/// Five proposals each defined a partial copy — `ACountFromOutsideNeedsACeiling` and
/// `ATrapIsAnOutage` (Decodable / Content, MCP accessors, CLI and environment),
/// `BytesFromOutsideNeedACeiling` (file and network bytes), `APatternIsAProgram` (a workbook
/// cell), `AStringThatEndsALineStartsAnother` and `AnErrorIsNotAResponse` (request accessors).
/// This is their union, with each ``Kind`` tagged by the proposals it came from.
///
/// The model is **syntactic, decidable and one function wide**, and free of SwiftSyntax for the
/// same reason ``SecurityContext`` is: `QualityGateCore` does not link the parser, and a model
/// over plain values can be tested exhaustively. A visitor describes an expression as an
/// ``Expression`` and the function around it as a ``Scope``; the `ExternalInputSyntax` target
/// does that from a SwiftSyntax tree.
///
/// ## Sources
///
/// | ``Kind`` | recognised by | reach |
/// |---|---|---|
/// | `requestContent` | `req.content`, `.query`, `.parameters`, `.headers`, `.body`, `.cookies`, `.url` on a `Request` parameter (an untyped closure parameter named `req`/`request` in a file importing Vapor or Hummingbird); a parameter whose type is in ``Vocabulary/contentTypes`` | network |
/// | `mcpArgument` | an accessor in ``Vocabulary/mcpAccessors`` called with an unlabelled key (`args.getInt("n")`); a parameter typed `[String: AnyCodable]`, `[String: Value]` or `CallTool.Parameters` | network |
/// | `commandLine` | `CommandLine.arguments`, `ProcessInfo.processInfo.arguments`; an `@Argument` / `@Option` / `@Flag` property of the enclosing type | local |
/// | `environment` | `ProcessInfo.processInfo.environment`, `getenv(_:)`, Vapor `Environment.get(_:)` | local |
/// | `fileBytes` | `Data`/`String`/`NSData`/`NSString(contentsOf…:)`, `FileManager.contents(atPath:)`, `FileHandle` reads, `readLine()` | unknown |
/// | `networkBytes` | `data`/`bytes`/`download`/`upload(from:/for:)` on a receiver named for a session; NIO `ByteBuffer` reads | network |
/// | `documentCell` | a parameter whose type names one of ``Vocabulary/documentCellTypes`` (`CellValue`) | unknown |
/// | `decodedValue` | `decode(_:from:)` whose bytes are not themselves traced | unknown |
///
/// ## Propagation, within one function
///
/// - a `let`/`var`/`if let`/`guard let`/`case let`/`for` binding is followed to its initialiser,
///   at most ``maximumHops`` times;
/// - member access and subscript on an external value are external (*direct*);
/// - a conversion initialiser (`Int(x)`, `String(x)`, `URL(string: x)`, …) keeps it external
///   (*direct*);
/// - a method called on an external value, a string interpolation, a binary operator, a ternary
///   and a collection literal containing one are external (*not direct*).
///
/// *Direct* is ``Trace/isDirect``: the value is the source under a name — what
/// `ATrapIsAnOutage.md` §3.2 calls "that source under a name" — rather than something computed
/// from it.
///
/// ## What is not tracked
///
/// - **Anything across a function boundary.** A free function's result is not traced even when an
///   argument is external, and a plain parameter is not a source. A value derived from one is
///   reported as ``Derivation/parameter(_:path:)``, with the parameter's index, so a later rule
///   can take **one call hop** by classifying the arguments at the function's call sites.
///   The measured cost of the limit: 86 of 120 (72%) MCP integer arguments in businessMathMCP
///   leave the function they arrive in (`ATrapIsAnOutage.md` §8).
/// - **Reassignment.** Only a binding's initialiser is followed; `p = input` after
///   `var p = ""` is not.
/// - **Stored properties and globals**, other than ArgumentParser properties.
/// - **A subscript's index.** `table[i]` with an external `i` is not an external value.
/// - **Callback parameters.** `dataTask(with:) { data, _, _ in … }` — `data` is not a source.
/// - **Lexical block scope.** The scope a visitor builds is every binding declared earlier in the
///   function, so a binding in an earlier sibling block can shadow; that over-reports, never
///   under-reports.
///
/// ## Usage
///
/// ```swift
/// // `guard let pattern = args.getString("pattern")` earlier in an MCP tool's body; is the
/// // expression `pattern.lowercased()` external?
/// let scope = ExternalInput.Scope(bindings: [
///     "pattern": .call(.member(.name("args"), "getString"), [.init(label: nil, value: .literal)]),
/// ])
/// let expression = ExternalInput.Expression.call(.member(.name("pattern"), "lowercased"), [])
/// if let trace = ExternalInput.trace(of: expression, in: scope) {
///     // .mcpArgument, evidence "getString", path ["pattern"], not direct
///     print(trace.kind.phrase, trace.evidence, trace.path, trace.isDirect)
/// }
/// ```
public enum ExternalInput {

    /// How many bindings a chain may pass through before it is no longer followed.
    public static let maximumHops = 8

    /// Expression depth past which nothing is examined — a guard for the recursion, not a model
    /// decision; no expression in the portfolio comes near it.
    static let maximumDepth = 64

    // MARK: - Kinds

    /// Who can choose the value, as `ACountFromOutsideNeedsACeiling.md` §3.2 grades it.
    public enum Reach: String, Sendable, Hashable, CaseIterable {
        /// Whoever can send the process a request.
        case network
        /// The person running the process.
        case local
        /// Depends on where the bytes came from, which one function cannot see.
        case unknown
    }

    /// A proposal, and the section of it, that defined part of the model.
    public struct Origin: Sendable, Hashable {
        /// The proposal's file name, without `.md`.
        public let proposal: String
        /// The section that defines the source.
        public let section: String

        /// Creates an origin.
        public init(proposal: String, section: String) {
            self.proposal = proposal
            self.section = section
        }
    }

    /// The kinds of external input.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// Content of an HTTP request: body, query, path parameters, headers, cookies, URL.
        case requestContent
        /// An argument to an MCP tool call.
        case mcpArgument
        /// The process's command line, including ArgumentParser properties.
        case commandLine
        /// The process's environment.
        case environment
        /// Bytes read from a file or standard input.
        case fileBytes
        /// Bytes read from the network.
        case networkBytes
        /// A cell value of a workbook or document being evaluated.
        case documentCell
        /// A value decoded from bytes the function did not trace.
        case decodedValue

        /// Who can choose a value of this kind.
        public var reach: Reach {
            switch self {
            case .requestContent, .mcpArgument, .networkBytes: return .network
            case .commandLine, .environment: return .local
            case .fileBytes, .documentCell, .decodedValue: return .unknown
            }
        }

        /// The proposals whose partial definitions this kind unifies.
        public var origins: [Origin] {
            switch self {
            case .requestContent:
                return [Origin(proposal: "ACountFromOutsideNeedsACeiling", section: "3.2"),
                        Origin(proposal: "ATrapIsAnOutage", section: "3.2"),
                        Origin(proposal: "AStringThatEndsALineStartsAnother", section: "3.3"),
                        Origin(proposal: "AnErrorIsNotAResponse", section: "9")]
            case .mcpArgument, .commandLine, .environment:
                return [Origin(proposal: "ACountFromOutsideNeedsACeiling", section: "3.2"),
                        Origin(proposal: "ATrapIsAnOutage", section: "3.2")]
            case .fileBytes, .networkBytes:
                return [Origin(proposal: "BytesFromOutsideNeedACeiling", section: "3.3")]
            case .documentCell:
                return [Origin(proposal: "APatternIsAProgram", section: "2"),
                        Origin(proposal: "ATrapIsAnOutage", section: "3.7")]
            case .decodedValue:
                return [Origin(proposal: "ACountFromOutsideNeedsACeiling", section: "3.2")]
            }
        }

        /// The kind in words, for a diagnostic: "an MCP tool argument".
        public var phrase: String {
            switch self {
            case .requestContent: return "HTTP request content"
            case .mcpArgument: return "an MCP tool argument"
            case .commandLine: return "the command line"
            case .environment: return "the environment"
            case .fileBytes: return "file contents"
            case .networkBytes: return "bytes from the network"
            case .documentCell: return "a document cell"
            case .decodedValue: return "a decoded value"
            }
        }
    }

    // MARK: - What a visitor hands over

    /// An expression, as much of it as the model reads.
    ///
    /// A visitor strips `try`, `await`, parentheses, `?`, `!` and `as` casts before describing,
    /// writes `self.x` as `.member(.name("self"), "x")`, and describes anything it does not model
    /// — a closure, a key path — as ``opaque``.
    public indirect enum Expression: Sendable, Hashable {
        /// A bare identifier.
        case name(String)
        /// `base.name`; `nil` base for an implicit member (`.text`).
        case member(Expression?, String)
        /// A call: the callee and its arguments as written.
        case call(Expression, [Argument])
        /// `base[arguments]`.
        case subscripted(Expression, [Argument])
        /// A string literal with interpolations: the interpolated expressions. A literal segment
        /// is not listed.
        case interpolated([Expression])
        /// An operator expression, a ternary, an array, dictionary or tuple literal: its parts.
        case combined([Expression])
        /// A literal with no interpolation.
        case literal
        /// Something the model does not read.
        case opaque
    }

    /// A call or subscript argument.
    public struct Argument: Sendable, Hashable {
        /// The label as written; `nil` when unlabelled.
        public let label: String?
        /// The argument.
        public let value: Expression

        /// Creates an argument.
        public init(label: String?, value: Expression) {
            self.label = label
            self.value = value
        }
    }

    /// A parameter of the function (or of an enclosing closure) the expression is in.
    public struct Parameter: Sendable, Hashable {
        /// The name the body uses — the second name when there are two.
        public let name: String
        /// The declared type as written; `nil` for an untyped closure parameter.
        public let type: String?
        /// The parameter's position in its list.
        public let index: Int

        /// Creates a parameter.
        public init(name: String, type: String?, index: Int) {
            self.name = name
            self.type = type
            self.index = index
        }
    }

    /// What is in scope at the expression.
    public struct Scope: Sendable {
        /// Each name bound earlier in the function, to the expression it was bound from — the
        /// latest binding when a name is bound more than once.
        public var bindings: [String: Expression]
        /// The function's parameters, and those of every closure between it and the expression.
        public var parameters: [Parameter]
        /// `@Argument` / `@Option` / `@Flag` properties of the enclosing type.
        public var commandLineProperties: Set<String>
        /// The modules the file imports.
        public var imports: Set<String>

        /// Creates a scope.
        public init(
            bindings: [String: Expression] = [:],
            parameters: [Parameter] = [],
            commandLineProperties: Set<String> = [],
            imports: Set<String> = []
        ) {
            self.bindings = bindings
            self.parameters = parameters
            self.commandLineProperties = commandLineProperties
            self.imports = imports
        }
    }

    /// The names the model recognises by spelling, where a project can add its own.
    public struct Vocabulary: Sendable {
        /// Types known to conform to Vapor `Content`. A visitor adds those declared in the file.
        public var contentTypes: Set<String>
        /// Types whose values are cells of a document being evaluated.
        public var documentCellTypes: Set<String>
        /// SwiftMCPServer's argument accessors — the list `MCPSchemaVisitor` checks schemas
        /// against.
        public var mcpAccessors: Set<String>

        /// Creates a vocabulary.
        public init(contentTypes: Set<String>, documentCellTypes: Set<String>, mcpAccessors: Set<String>) {
            self.contentTypes = contentTypes
            self.documentCellTypes = documentCellTypes
            self.mcpAccessors = mcpAccessors
        }

        /// The vocabulary with no project additions.
        public static let standard = Vocabulary(
            contentTypes: [],
            documentCellTypes: ["CellValue"],
            mcpAccessors: [
                "getString", "getStringOptional", "getInt", "getIntOptional",
                "getDouble", "getDoubleOptional", "getBool", "getBoolOptional",
                "getDoubleArray", "getDoubleArrayOptional", "getStringArray", "getStringArrayOptional",
                "getDoubleMatrix", "getDoubleMatrixOptional", "getDoubleFromObject",
                "getStringArrayIfPresent", "getDoubleArrayIfPresent", "getDoubleMatrixIfPresent",
            ])

        /// This vocabulary with more `Content` types.
        public func addingContentTypes(_ types: Set<String>) -> Vocabulary {
            var copy = self
            copy.contentTypes.formUnion(types)
            return copy
        }
    }

    // MARK: - What the model answers

    /// How an expression reaches a source.
    public struct Trace: Sendable, Equatable {
        /// The kind of source.
        public let kind: Kind
        /// What was recognised, as source-shaped text: `req.query`, `getInt`,
        /// `args: [CellValue]`.
        public let evidence: String
        /// The bindings followed from the expression to the source, nearest first.
        public let path: [String]
        /// Whether the value is the source under a name, rather than computed from it.
        public let isDirect: Bool

        /// Creates a trace.
        public init(kind: Kind, evidence: String, path: [String], isDirect: Bool) {
            self.kind = kind
            self.evidence = evidence
            self.path = path
            self.isDirect = isDirect
        }
    }

    /// Where an expression comes from, when the model can say.
    public enum Derivation: Sendable, Equatable {
        /// From an external source.
        case external(Trace)
        /// From a parameter that is not itself a source — the one-call-hop extension point.
        case parameter(Parameter, path: [String])
    }

    /// The external source `expression` derives from, if any.
    public static func trace(
        of expression: Expression,
        in scope: Scope,
        vocabulary: Vocabulary = .standard
    ) -> Trace? {
        guard case .external(let trace) = derivation(of: expression, in: scope, vocabulary: vocabulary) else {
            return nil
        }
        return trace
    }

    /// Where `expression` derives from: an external source, a plain parameter, or neither (`nil`).
    ///
    /// When parts of the expression derive from both, the external part is the answer.
    public static func derivation(
        of expression: Expression,
        in scope: Scope,
        vocabulary: Vocabulary = .standard
    ) -> Derivation? {
        Walker(vocabulary: vocabulary).derive(expression, in: scope, Step())
    }

    /// `expression` written back as source-shaped text, with arguments elided.
    public static func render(_ expression: Expression) -> String {
        Walker.render(expression, depth: 0)
    }
}

// MARK: - The walk

extension ExternalInput {

    /// Where the walk is: the bindings followed so far, and whether the value is still the
    /// source under a name.
    struct Step {
        var hops = 0
        var path: [String] = []
        var isDirect = true
        var depth = 0

        func deeper(direct: Bool = true) -> Step {
            var next = self
            next.depth += 1
            next.isDirect = isDirect && direct
            return next
        }

        func following(_ name: String) -> Step {
            var next = deeper()
            next.hops += 1
            next.path.append(name)
            return next
        }
    }

    struct Walker {
        let vocabulary: Vocabulary

        static let requestMembers: Set<String> = ["content", "query", "parameters", "headers", "body", "cookies", "url"]
        static let conversions: Set<String> = [
            "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Double", "Float", "Float32", "Float64", "CGFloat", "Decimal", "Bool",
            "String", "Substring", "Character", "NSString", "Data", "URL", "URLComponents", "Array", "Set",
        ]
        static let fileReaders: Set<String> = ["readDataToEndOfFile", "readToEnd"]
        static let nioReads: Set<String> = ["readString", "readBytes", "readSlice", "readInteger", "readJSONDecodable"]
        static let nioGets: Set<String> = ["getString", "getBytes", "getSlice", "getInteger", "getData"]
        static let sessionCalls: Set<String> = ["data", "bytes", "download", "upload"]
        static let mcpArgumentTypes: Set<String> = ["[String:AnyCodable]", "[String:MCP.Value]", "[String:Value]"]

        func derive(_ expression: Expression, in scope: Scope, _ step: Step) -> Derivation? {
            guard step.depth < ExternalInput.maximumDepth else { return nil }
            if let source = recognise(expression, in: scope, step) {
                return .external(source)
            }
            switch expression {
            case .name(let name):
                return resolve(name, in: scope, step)
            case .member(let base, _):
                guard let base, base != .name("self") else { return nil }
                return derive(base, in: scope, step.deeper())
            case .call(let callee, let arguments):
                return deriveCall(callee, arguments, in: scope, step)
            case .subscripted(let base, _):
                return derive(base, in: scope, step.deeper())
            case .interpolated(let parts), .combined(let parts):
                return first(parts, in: scope, step.deeper(direct: false))
            case .literal, .opaque:
                return nil
            }
        }

        private func deriveCall(_ callee: Expression, _ arguments: [Argument], in scope: Scope, _ step: Step) -> Derivation? {
            if case .name(let type) = callee, Self.conversions.contains(type) {
                return first(arguments.map(\.value), in: scope, step.deeper())
            }
            if case .member(let base?, let method) = callee {
                return derive(base, in: scope, step.deeper(direct: method == "decode"))
            }
            return nil
        }

        /// The first part that derives from outside; failing that, the first from a parameter.
        private func first(_ parts: [Expression], in scope: Scope, _ step: Step) -> Derivation? {
            var fromParameter: Derivation?
            for part in parts {
                switch derive(part, in: scope, step) {
                case .external(let trace)?:
                    return .external(trace)
                case .parameter(let parameter, let path)?:
                    fromParameter = fromParameter ?? .parameter(parameter, path: path)
                case nil:
                    continue
                }
            }
            return fromParameter
        }

        private func resolve(_ name: String, in scope: Scope, _ step: Step) -> Derivation? {
            if let initialiser = scope.bindings[name] {
                guard step.hops < ExternalInput.maximumHops else { return nil }
                // The initialiser is read without its own binding, so `guard let args = args`
                // resolves the right-hand `args` to the parameter, not to itself.
                var outer = scope
                outer.bindings[name] = nil
                return derive(initialiser, in: outer, step.following(name))
            }
            if let parameter = scope.parameters.last(where: { $0.name == name }) {
                if let source = parameterSource(parameter, in: scope, step) {
                    return .external(source)
                }
                return .parameter(parameter, path: step.path)
            }
            if scope.commandLineProperties.contains(name) {
                return .external(trace(.commandLine, "@Argument/@Option/@Flag \(name)", step))
            }
            return nil
        }

        // MARK: Recognising a source

        private func trace(_ kind: Kind, _ evidence: String, _ step: Step) -> Trace {
            Trace(kind: kind, evidence: evidence, path: step.path, isDirect: step.isDirect)
        }

        private func recognise(_ expression: Expression, in scope: Scope, _ step: Step) -> Trace? {
            switch expression {
            case .member(let base?, let name):
                return recogniseMember(base, name, in: scope, step)
            case .call(let callee, let arguments):
                return recogniseCall(callee, arguments, in: scope, step)
            default:
                return nil
            }
        }

        private func recogniseMember(_ base: Expression, _ name: String, in scope: Scope, _ step: Step) -> Trace? {
            let baseText = ExternalInput.render(base)
            switch (baseText, name) {
            case ("CommandLine", "arguments"), ("CommandLine", "unsafeArgv"),
                 ("ProcessInfo.processInfo", "arguments"):
                return trace(.commandLine, "\(baseText).\(name)", step)
            case ("ProcessInfo.processInfo", "environment"):
                return trace(.environment, "\(baseText).\(name)", step)
            case (_, "availableData"):
                return trace(.fileBytes, name, step)
            case (_, "readableBytesView"):
                return trace(.networkBytes, name, step)
            default:
                break
            }
            if base == .name("self"), scope.commandLineProperties.contains(name) {
                return trace(.commandLine, "@Argument/@Option/@Flag \(name)", step)
            }
            if case .name(let receiver) = base, Self.requestMembers.contains(name), isRequest(receiver, in: scope) {
                return trace(.requestContent, "\(receiver).\(name)", step)
            }
            return nil
        }

        private func recogniseCall(_ callee: Expression, _ arguments: [Argument], in scope: Scope, _ step: Step) -> Trace? {
            let labels = arguments.map(\.label)
            switch callee {
            case .name("getenv"):
                return trace(.environment, "getenv", step)
            case .name("readLine"):
                return trace(.fileBytes, "readLine()", step)
            case .name(let type) where ["Data", "NSData", "String", "NSString"].contains(type):
                guard let found = labels.first(where: { $0 == "contentsOf" || $0 == "contentsOfFile" }),
                      let label = found else { return nil }
                return trace(.fileBytes, "\(type)(\(label):)", step)
            case .member(let base?, let method):
                return recogniseMethod(base, method, arguments, in: scope, step)
            default:
                return nil
            }
        }

        private func recogniseMethod(
            _ base: Expression, _ method: String, _ arguments: [Argument],
            in scope: Scope, _ step: Step
        ) -> Trace? {
            let labels = arguments.map(\.label)
            let baseText = ExternalInput.render(base)
            if baseText == "Environment", method == "get" {
                return trace(.environment, "Environment.get", step)
            }
            if vocabulary.mcpAccessors.contains(method), !arguments.isEmpty, labels[0] == nil {
                return trace(.mcpArgument, method, step)
            }
            if Self.fileReaders.contains(method), arguments.isEmpty {
                return trace(.fileBytes, "\(method)()", step)
            }
            if (method == "readData" && labels.first == "ofLength") || (method == "read" && labels.first == "upToCount")
                || (method == "contents" && labels.first == "atPath") {
                return trace(.fileBytes, "\(method)(\(labels.first.flatMap { $0 } ?? ""):)", step)
            }
            if Self.sessionCalls.contains(method), let label = labels.first.flatMap({ $0 }),
               label == "from" || label == "for", baseText.lowercased().contains("session") {
                return trace(.networkBytes, "\(baseText).\(method)(\(label):)", step)
            }
            if Self.nioReads.contains(method) || (method == "readData" && labels.first == "length") {
                return trace(.networkBytes, method, step)
            }
            if Self.nioGets.contains(method), labels.first == "at" {
                return trace(.networkBytes, "\(method)(at:)", step)
            }
            if method == "decode", let bytes = arguments.first(where: { $0.label == "from" }) {
                if case .external(let traced)? = derive(bytes.value, in: scope, step.deeper()) {
                    return traced
                }
                return trace(.decodedValue, "decode(_:from:)", step)
            }
            return nil
        }

        /// Whether `name` is a parameter that is an HTTP request.
        private func isRequest(_ name: String, in scope: Scope) -> Bool {
            guard let parameter = scope.parameters.last(where: { $0.name == name }) else { return false }
            let serverFramework = scope.imports.contains("Vapor") || scope.imports.contains("Hummingbird")
            guard let type = parameter.type.map(Self.normalised) else {
                return serverFramework && (name == "req" || name == "request")
            }
            return type == "Vapor.Request" || (type == "Request" && serverFramework)
        }

        private func parameterSource(_ parameter: Parameter, in scope: Scope, _ step: Step) -> Trace? {
            guard let written = parameter.type else { return nil }
            let type = Self.normalised(written)
            let evidence = "\(parameter.name): \(written)"
            let element = type.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if vocabulary.contentTypes.contains(element) {
                return trace(.requestContent, "\(evidence) (Content)", step)
            }
            let mcpModule = scope.imports.contains("MCP") || scope.imports.contains("SwiftMCPServer")
            if type == "CallTool.Parameters"
                || (Self.mcpArgumentTypes.contains(type) && (type != "[String:Value]" || mcpModule)) {
                return trace(.mcpArgument, evidence, step)
            }
            let words = Set(type.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init))
            if !words.isDisjoint(with: vocabulary.documentCellTypes) {
                return trace(.documentCell, evidence, step)
            }
            return nil
        }

        /// A type as written, without spaces, ownership, attributes or a trailing `?` / `!`.
        static func normalised(_ type: String) -> String {
            var words = type.split(separator: " ").map(String.init)
            words.removeAll { $0.hasPrefix("@") || ["inout", "borrowing", "consuming", "sending"].contains($0) }
            var text = words.joined()
            while let last = text.last, last == "?" || last == "!" {
                text.removeLast()
            }
            return text
        }

        // MARK: Rendering

        static func render(_ expression: Expression, depth: Int) -> String {
            guard depth < ExternalInput.maximumDepth else { return "…" }
            switch expression {
            case .name(let name):
                return name
            case .member(let base, let name):
                return (base.map { render($0, depth: depth + 1) } ?? "") + "." + name
            case .call(let callee, let arguments):
                return render(callee, depth: depth + 1) + (arguments.isEmpty ? "()" : "(…)")
            case .subscripted(let base, _):
                return render(base, depth: depth + 1) + "[…]"
            case .interpolated:
                return "\"…\""
            case .combined, .opaque:
                return "…"
            case .literal:
                return "literal"
            }
        }
    }
}
