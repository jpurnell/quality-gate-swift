import Foundation
import Testing
@testable import QualityGateCore

/// The shared external-input source model (`TheGateIsNotYetAggressive.md` §2.2 item 3).
///
/// Contract under test: within one function body, an expression is external when it *is* one of
/// the recognised sources, or is reached from one by binding chains (at most
/// ``ExternalInput/maximumHops``), member access, subscript, a conversion initialiser, a method
/// called on it, interpolation or combination. A plain parameter is reported as a parameter — the
/// one-call-hop extension point — and nothing crosses a function boundary.
private func call(_ callee: ExternalInput.Expression, _ arguments: ExternalInput.Argument...) -> ExternalInput.Expression {
    .call(callee, arguments)
}

private func member(_ base: ExternalInput.Expression, _ name: String) -> ExternalInput.Expression {
    .member(base, name)
}

private func arg(_ value: ExternalInput.Expression, _ label: String? = nil) -> ExternalInput.Argument {
    ExternalInput.Argument(label: label, value: value)
}

@Suite("ExternalInput")
struct ExternalInputTests {

    typealias E = ExternalInput.Expression
    typealias A = ExternalInput.Argument

    private static func scope(
        bindings: [String: E] = [:],
        parameters: [ExternalInput.Parameter] = [],
        commandLineProperties: Set<String> = [],
        imports: Set<String> = []
    ) -> ExternalInput.Scope {
        ExternalInput.Scope(
            bindings: bindings, parameters: parameters,
            commandLineProperties: commandLineProperties, imports: imports)
    }

    private static func parameter(_ name: String, _ type: String?, _ index: Int = 0) -> ExternalInput.Parameter {
        ExternalInput.Parameter(name: name, type: type, index: index)
    }


    // MARK: - Every source kind, with its evidence

    /// One row per recognised source: the expression, the scope it is read in, the kind and the
    /// evidence the trace must carry.
    struct SourceCase: CustomTestStringConvertible, Sendable {
        let expression: E
        let scope: ExternalInput.Scope
        let kind: ExternalInput.Kind
        let evidence: String
        var testDescription: String { evidence }
    }

    static let vapor = scope(parameters: [parameter("req", "Request")], imports: ["Vapor"])

    static let sourceCases: [SourceCase] = [
        // Request content (Vapor)
        SourceCase(expression: call(member(member(.name("req"), "content"), "decode"), arg(member(.name("Body"), "self"))),
                   scope: vapor, kind: .requestContent, evidence: "req.content"),
        SourceCase(expression: .subscripted(member(.name("req"), "query"), [arg(.literal)]),
                   scope: vapor, kind: .requestContent, evidence: "req.query"),
        SourceCase(expression: call(member(member(.name("req"), "parameters"), "get"), arg(.literal)),
                   scope: vapor, kind: .requestContent, evidence: "req.parameters"),
        SourceCase(expression: member(member(.name("req"), "headers"), "first"),
                   scope: vapor, kind: .requestContent, evidence: "req.headers"),
        SourceCase(expression: member(member(.name("req"), "body"), "string"),
                   scope: vapor, kind: .requestContent, evidence: "req.body"),
        SourceCase(expression: member(.name("request"), "url"),
                   scope: scope(parameters: [parameter("request", nil)], imports: ["Vapor"]),
                   kind: .requestContent, evidence: "request.url"),
        SourceCase(expression: member(.name("input"), "horizon"),
                   scope: scope(parameters: [parameter("input", "RunwayRequest")]),
                   kind: .requestContent, evidence: "input: RunwayRequest (Content)"),
        // MCP tool arguments
        SourceCase(expression: call(member(.name("args"), "getInt"), arg(.literal)),
                   scope: scope(), kind: .mcpArgument, evidence: "getInt"),
        SourceCase(expression: call(member(.name("args"), "getStringOptional"), arg(.literal)),
                   scope: scope(), kind: .mcpArgument, evidence: "getStringOptional"),
        SourceCase(expression: member(.subscripted(.name("arguments"), [arg(.literal)]), "stringValue"),
                   scope: scope(parameters: [parameter("arguments", "[String: AnyCodable]?")]),
                   kind: .mcpArgument, evidence: "arguments: [String: AnyCodable]?"),
        SourceCase(expression: .subscripted(member(.name("params"), "arguments"), [arg(.literal)]),
                   scope: scope(parameters: [parameter("params", "CallTool.Parameters")]),
                   kind: .mcpArgument, evidence: "params: CallTool.Parameters"),
        // Command line and environment
        SourceCase(expression: .subscripted(member(.name("CommandLine"), "arguments"), [arg(.literal)]),
                   scope: scope(), kind: .commandLine, evidence: "CommandLine.arguments"),
        SourceCase(expression: member(member(.name("ProcessInfo"), "processInfo"), "arguments"),
                   scope: scope(), kind: .commandLine, evidence: "ProcessInfo.processInfo.arguments"),
        SourceCase(expression: .name("pattern"),
                   scope: scope(commandLineProperties: ["pattern"]), kind: .commandLine,
                   evidence: "@Argument/@Option/@Flag pattern"),
        SourceCase(expression: member(.name("self"), "pattern"),
                   scope: scope(commandLineProperties: ["pattern"]), kind: .commandLine,
                   evidence: "@Argument/@Option/@Flag pattern"),
        SourceCase(expression: .subscripted(member(member(.name("ProcessInfo"), "processInfo"), "environment"), [arg(.literal)]),
                   scope: scope(), kind: .environment, evidence: "ProcessInfo.processInfo.environment"),
        SourceCase(expression: call(.name("getenv"), arg(.literal)),
                   scope: scope(), kind: .environment, evidence: "getenv"),
        SourceCase(expression: call(member(.name("Environment"), "get"), arg(.literal)),
                   scope: scope(), kind: .environment, evidence: "Environment.get"),
        // File bytes
        SourceCase(expression: call(.name("Data"), arg(.name("url"), "contentsOf")),
                   scope: scope(), kind: .fileBytes, evidence: "Data(contentsOf:)"),
        SourceCase(expression: call(.name("String"), arg(.name("url"), "contentsOf"), arg(.opaque, "encoding")),
                   scope: scope(), kind: .fileBytes, evidence: "String(contentsOf:)"),
        SourceCase(expression: call(.name("String"), arg(.name("path"), "contentsOfFile")),
                   scope: scope(), kind: .fileBytes, evidence: "String(contentsOfFile:)"),
        SourceCase(expression: call(member(member(.name("FileManager"), "default"), "contents"), arg(.name("p"), "atPath")),
                   scope: scope(), kind: .fileBytes, evidence: "contents(atPath:)"),
        SourceCase(expression: call(member(.name("handle"), "readToEnd")),
                   scope: scope(), kind: .fileBytes, evidence: "readToEnd()"),
        SourceCase(expression: call(member(.name("handle"), "readDataToEndOfFile")),
                   scope: scope(), kind: .fileBytes, evidence: "readDataToEndOfFile()"),
        SourceCase(expression: call(member(.name("handle"), "read"), arg(.literal, "upToCount")),
                   scope: scope(), kind: .fileBytes, evidence: "read(upToCount:)"),
        SourceCase(expression: member(.name("handle"), "availableData"),
                   scope: scope(), kind: .fileBytes, evidence: "availableData"),
        SourceCase(expression: call(.name("readLine")),
                   scope: scope(), kind: .fileBytes, evidence: "readLine()"),
        // Network bytes
        SourceCase(expression: call(member(member(.name("URLSession"), "shared"), "data"), arg(.name("url"), "from")),
                   scope: scope(), kind: .networkBytes, evidence: "URLSession.shared.data(from:)"),
        SourceCase(expression: call(member(.name("session"), "bytes"), arg(.name("request"), "for")),
                   scope: scope(), kind: .networkBytes, evidence: "session.bytes(for:)"),
        SourceCase(expression: call(member(.name("buffer"), "readString"), arg(.literal, "length")),
                   scope: scope(), kind: .networkBytes, evidence: "readString"),
        SourceCase(expression: call(member(.name("buffer"), "getString"), arg(.literal, "at"), arg(.literal, "length")),
                   scope: scope(), kind: .networkBytes, evidence: "getString(at:)"),
        SourceCase(expression: member(.name("buffer"), "readableBytesView"),
                   scope: scope(), kind: .networkBytes, evidence: "readableBytesView"),
        // Document cells
        SourceCase(expression: member(.subscripted(.name("args"), [arg(.literal)]), "resolved"),
                   scope: scope(parameters: [parameter("args", "[CellValue]")]),
                   kind: .documentCell, evidence: "args: [CellValue]"),
        // A decode whose bytes are not themselves traced
        SourceCase(expression: call(member(.name("decoder"), "decode"), arg(member(.name("Config"), "self")), arg(.name("blob"), "from")),
                   scope: scope(), kind: .decodedValue, evidence: "decode(_:from:)"),
    ]

    @Test("every source kind is recognised, with the evidence that decided it", arguments: sourceCases)
    func recognisesSource(_ row: SourceCase) {
        let vocabulary = ExternalInput.Vocabulary.standard.addingContentTypes(["RunwayRequest"])
        let trace = ExternalInput.trace(of: row.expression, in: row.scope, vocabulary: vocabulary)
        #expect(trace?.kind == row.kind)
        #expect(trace?.evidence == row.evidence)
    }

    /// The origin-tagged table: each kind's reach, its phrase in a diagnostic, and the
    /// `proposal §section` pairs whose partial definitions it unifies.
    static let kindTable: [(ExternalInput.Kind, ExternalInput.Reach, String, [String])] = [
        (.requestContent, .network, "HTTP request content",
         ["ACountFromOutsideNeedsACeiling §3.2", "ATrapIsAnOutage §3.2",
          "AStringThatEndsALineStartsAnother §3.3", "AnErrorIsNotAResponse §9"]),
        (.mcpArgument, .network, "an MCP tool argument",
         ["ACountFromOutsideNeedsACeiling §3.2", "ATrapIsAnOutage §3.2"]),
        (.commandLine, .local, "the command line",
         ["ACountFromOutsideNeedsACeiling §3.2", "ATrapIsAnOutage §3.2"]),
        (.environment, .local, "the environment",
         ["ACountFromOutsideNeedsACeiling §3.2", "ATrapIsAnOutage §3.2"]),
        (.fileBytes, .unknown, "file contents", ["BytesFromOutsideNeedACeiling §3.3"]),
        (.networkBytes, .network, "bytes from the network", ["BytesFromOutsideNeedACeiling §3.3"]),
        (.documentCell, .unknown, "a document cell", ["APatternIsAProgram §2", "ATrapIsAnOutage §3.7"]),
        (.decodedValue, .unknown, "a decoded value", ["ACountFromOutsideNeedsACeiling §3.2"]),
    ]

    @Test("every kind carries its reach, its phrase and its originating proposals", arguments: kindTable)
    func kindsAreTagged(kind: ExternalInput.Kind, reach: ExternalInput.Reach, phrase: String, origins: [String]) {
        #expect(kind.reach == reach)
        #expect(kind.phrase == phrase)
        #expect(kind.origins.map { "\($0.proposal) §\($0.section)" } == origins)
    }

    @Test("the table covers every kind")
    func kindTableIsComplete() {
        #expect(Set(Self.kindTable.map(\.0)) == Set(ExternalInput.Kind.allCases))
        #expect(Self.kindTable.count == 8)
    }

    // MARK: - Not sources

    @Test("a look-alike that is not a source is not external", arguments: [
        // `req` that is not a request: no Vapor import and no Request type
        (member(.name("req"), "query"), scope(parameters: [parameter("req", nil)])),
        // a request's non-input members
        (member(.name("req"), "logger"), vapor),
        (member(.name("req"), "db"), vapor),
        // an MCP accessor spelled with a label is NIO's `getString(at:length:)` family only when
        // its receiver is a buffer; a labelled `getInt(forKey:)` is neither
        (call(member(.name("defaults"), "getInt"), arg(.literal, "forKey")), scope()),
        // `data(from:)` on something that is not a session
        (call(member(.name("decoder"), "data"), arg(.name("x"), "from")), scope()),
        // a literal and an opaque expression
        (E.literal, scope()),
        (E.opaque, scope()),
        // a Decodable that is not Content, as a parameter
        (member(.name("config"), "pattern"), scope(parameters: [parameter("config", "GateConfig")])),
    ] as [(E, ExternalInput.Scope)])
    func notASource(expression: E, scope: ExternalInput.Scope) {
        #expect(ExternalInput.trace(of: expression, in: scope) == nil)
    }

    // MARK: - Propagation within one body

    @Test("a let chain is followed, and the path names each binding")
    func bindingChain() {
        let s = Self.scope(bindings: [
            "pattern": .name("raw"),
            "raw": call(member(.name("args"), "getString"), arg(.literal)),
        ])
        let trace = ExternalInput.trace(of: .name("pattern"), in: s)
        #expect(trace?.kind == .mcpArgument)
        #expect(trace?.path == ["pattern", "raw"])
        #expect(trace?.isDirect == true)
    }

    @Test("member access and subscript on an external value are external and direct")
    func memberAndSubscript() {
        let s = Self.scope(bindings: ["cells": call(.name("Data"), arg(.name("u"), "contentsOf"))])
        let trace = ExternalInput.trace(of: member(.subscripted(.name("cells"), [arg(.literal)]), "first"), in: s)
        #expect(trace?.kind == .fileBytes)
        #expect(trace?.isDirect == true)
    }

    @Test("an interpolation containing an external value is external, not direct")
    func interpolation() {
        let s = Self.scope(bindings: ["name": call(.name("getenv"), arg(.literal))])
        let trace = ExternalInput.trace(of: .interpolated([.literal, .name("name")]), in: s)
        #expect(trace?.kind == .environment)
        #expect(trace?.isDirect == false)
        #expect(trace?.path == ["name"])
    }

    @Test("concatenation, ternary and collection literals carry an external part")
    func combination() {
        let s = Self.scope(bindings: ["q": .subscripted(member(.name("CommandLine"), "arguments"), [arg(.literal)])])
        #expect(ExternalInput.trace(of: .combined([.literal, .name("q")]), in: s)?.kind == .commandLine)
        #expect(ExternalInput.trace(of: .combined([.literal, .literal]), in: s) == nil)
    }

    @Test("a conversion initialiser keeps the value external and direct", arguments: ["Int", "Double", "String", "URL", "Data"])
    func conversion(type: String) {
        let s = Self.scope(bindings: ["text": call(member(.name("args"), "getString"), arg(.literal))])
        let trace = ExternalInput.trace(of: call(.name(type), arg(.name("text"))), in: s)
        #expect(trace?.kind == .mcpArgument)
        #expect(trace?.isDirect == true)
    }

    @Test("a method called on an external value is external, not direct")
    func methodOnExternal() {
        let s = Self.scope(parameters: [Self.parameter("args", "[CellValue]")])
        let trace = ExternalInput.trace(
            of: call(member(member(.subscripted(.name("args"), [arg(.literal)]), "text"), "replacingOccurrences"),
                     arg(.literal, "of"), arg(.literal, "with")),
            in: s)
        #expect(trace?.kind == .documentCell)
        #expect(trace?.isDirect == false)
    }

    @Test("a decode of traced bytes is those bytes' kind")
    func decodeOfTracedBytes() {
        let s = Self.scope(bindings: ["blob": call(.name("Data"), arg(.name("u"), "contentsOf"))])
        let decoded = call(member(.name("decoder"), "decode"), arg(member(.name("T"), "self")), arg(.name("blob"), "from"))
        #expect(ExternalInput.trace(of: decoded, in: s)?.kind == .fileBytes)
    }

    @Test("an external part wins over a parameter part")
    func externalBeatsParameter() {
        let s = Self.scope(
            bindings: ["e": call(.name("getenv"), arg(.literal))],
            parameters: [Self.parameter("prefix", "String")])
        let derivation = ExternalInput.derivation(of: .combined([.name("prefix"), .name("e")]), in: s)
        guard case .external(let trace) = derivation else {
            Issue.record("expected external, got \(String(describing: derivation))")
            return
        }
        #expect(trace.kind == .environment)
    }

    // MARK: - The extension point: a plain parameter

    @Test("a value from a plain parameter is reported as that parameter, with its index")
    func parameterDerivation() {
        let s = Self.scope(
            bindings: ["p": call(member(.name("pattern"), "lowercased"))],
            parameters: [Self.parameter("text", "String", 0), Self.parameter("pattern", "String", 1)])
        let derivation = ExternalInput.derivation(of: .name("p"), in: s)
        #expect(derivation == .parameter(Self.parameter("pattern", "String", 1), path: ["p"]))
        #expect(ExternalInput.trace(of: .name("p"), in: s) == nil)
    }

    // MARK: - Stated limits: what is not tracked

    @Test("a chain longer than maximumHops is not followed")
    func hopLimit() {
        var bindings: [String: E] = ["v0": call(.name("getenv"), arg(.literal))]
        for index in 1...ExternalInput.maximumHops {
            bindings["v\(index)"] = .name("v\(index - 1)")
        }
        let s = Self.scope(bindings: bindings)
        // maximumHops bindings followed reaches v0's initialiser…
        #expect(ExternalInput.trace(of: .name("v\(ExternalInput.maximumHops - 1)"), in: s)?.kind == .environment)
        // …one more is not.
        #expect(ExternalInput.trace(of: .name("v\(ExternalInput.maximumHops)"), in: s) == nil)
    }

    @Test("a free function's result is not traced, even from an external argument")
    func noCrossFunctionFlow() {
        let s = Self.scope(bindings: ["raw": call(member(.name("args"), "getString"), arg(.literal))])
        #expect(ExternalInput.trace(of: call(.name("sanitise"), arg(.name("raw"))), in: s) == nil)
        // …which is also how an escaper clears it.
        #expect(ExternalInput.trace(
            of: call(member(.name("NSRegularExpression"), "escapedPattern"), arg(.name("raw"), "for")),
            in: s) == nil)
    }

    @Test("a stored property or global is not traced")
    func propertiesAreNotTraced() {
        #expect(ExternalInput.derivation(of: member(.name("self"), "pattern"), in: Self.scope()) == nil)
        #expect(ExternalInput.derivation(of: .name("globalPattern"), in: Self.scope()) == nil)
    }

    @Test("a subscript's index does not make the element external")
    func indexIsNotTheValue() {
        let s = Self.scope(bindings: ["i": call(member(.name("args"), "getInt"), arg(.literal))])
        #expect(ExternalInput.trace(of: .subscripted(.name("table"), [arg(.name("i"))]), in: s) == nil)
    }

    @Test("a self-referential binding resolves to the outer name, not a loop")
    func shadowing() {
        let s = Self.scope(
            bindings: ["args": .name("args")],
            parameters: [Self.parameter("args", "[String: AnyCodable]?")])
        #expect(ExternalInput.trace(of: .name("args"), in: s)?.kind == .mcpArgument)
    }

    // MARK: - Rendering

    @Test("render writes an expression back as source-shaped text")
    func render() {
        #expect(ExternalInput.render(member(member(.name("req"), "content"), "decode")) == "req.content.decode")
        #expect(ExternalInput.render(call(member(.name("args"), "getInt"), arg(.literal))) == "args.getInt(…)")
        #expect(ExternalInput.render(.subscripted(.name("a"), [arg(.literal)])) == "a[…]")
        #expect(ExternalInput.render(.member(nil, "text")) == ".text")
    }
}
