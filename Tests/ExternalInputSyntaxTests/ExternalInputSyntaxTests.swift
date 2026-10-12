import Foundation
import Testing
import SwiftParser
import SwiftSyntax
import QualityGateCore
@testable import ExternalInputSyntax

/// The SwiftSyntax adapter for ``ExternalInput``: real source in, the model's answer out.
///
/// Each fixture marks the expression under test as the argument of `sink(…)`. The adapter
/// describes that expression, builds the scope around it — parameters, closure parameters, every
/// binding declared earlier in the function, ArgumentParser properties, imports, `Content` types
/// declared in the file — and asks the model.
@Suite("ExternalInputSyntax")
struct ExternalInputSyntaxTests {

    /// The derivation of the first argument of the first `sink(…)` call in `source`.
    private func derivation(_ source: String) throws -> ExternalInput.Derivation? {
        let file = Parser.parse(source: source)
        let finder = SinkFinder(viewMode: .sourceAccurate)
        finder.walk(file)
        let argument = try #require(finder.argument, "no sink(…) in fixture")
        return ExternalInputFile(file).derivation(of: argument)
    }

    private func trace(_ source: String) throws -> ExternalInput.Trace? {
        guard case .external(let trace)? = try derivation(source) else { return nil }
        return trace
    }

    // MARK: - Source kinds, from source text

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let source: String
        let kind: ExternalInput.Kind
        let evidence: String
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "Vapor query, typed handler", source: """
            import Vapor
            func search(req: Request) throws -> String {
                let term = try req.query.get(String.self, at: "q")
                return sink(term)
            }
            """, kind: .requestContent, evidence: "req.query"),
        Row(name: "Vapor content decode, untyped route closure", source: """
            import Vapor
            func routes(_ app: Application) {
                app.post("x") { req in
                    let body = try req.content.decode(Body.self)
                    return sink(body.horizon)
                }
            }
            """, kind: .requestContent, evidence: "req.content"),
        Row(name: "a parameter of a Content type declared in the file", source: """
            import Vapor
            struct RunwayRequest: Content { let horizon: Int }
            func project(_ request: RunwayRequest) {
                sink(request.horizon)
            }
            """, kind: .requestContent, evidence: "request: RunwayRequest (Content)"),
        Row(name: "a Content conformance added by extension", source: """
            import Vapor
            struct Plan { let months: Int }
            extension Plan: Content {}
            func run(plan: Plan) { sink(plan.months) }
            """, kind: .requestContent, evidence: "plan: Plan (Content)"),
        Row(name: "MCP accessor through guard let", source: """
            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missing }
                let seed = args.getIntOptional("seed")
                return sink(seed)
            }
            """, kind: .mcpArgument, evidence: "getIntOptional"),
        Row(name: "MCP argument dictionary subscript", source: """
            func execute(arguments: [String: AnyCodable]?) {
                sink(arguments?["formula"]?.stringValue)
            }
            """, kind: .mcpArgument, evidence: "arguments: [String: AnyCodable]?"),
        Row(name: "ArgumentParser option", source: """
            import ArgumentParser
            struct Grep: ParsableCommand {
                @Option var pattern: String
                func run() throws { sink(pattern) }
            }
            """, kind: .commandLine, evidence: "@Argument/@Option/@Flag pattern"),
        Row(name: "ArgumentParser argument through self, in an extension", source: """
            import ArgumentParser
            struct Grep: ParsableCommand {
                @Argument var pattern: String
            }
            extension Grep {
                func run() throws { sink(self.pattern) }
            }
            """, kind: .commandLine, evidence: "@Argument/@Option/@Flag pattern"),
        Row(name: "CommandLine.arguments", source: """
            let first = CommandLine.arguments[1]
            sink(first)
            """, kind: .commandLine, evidence: "CommandLine.arguments"),
        Row(name: "environment", source: """
            func configure() {
                let host = ProcessInfo.processInfo.environment["HOST"] ?? "localhost"
                sink(host)
            }
            """, kind: .environment, evidence: "ProcessInfo.processInfo.environment"),
        Row(name: "getenv", source: """
            func configure() { sink(String(cString: getenv("HOME"))) }
            """, kind: .environment, evidence: "getenv"),
        Row(name: "file bytes", source: """
            func load(url: URL) throws {
                let data = try Data(contentsOf: url)
                sink(String(decoding: data, as: UTF8.self))
            }
            """, kind: .fileBytes, evidence: "Data(contentsOf:)"),
        Row(name: "network bytes through a tuple", source: """
            func fetch(url: URL) async throws {
                let (data, _) = try await URLSession.shared.data(from: url)
                sink(data)
            }
            """, kind: .networkBytes, evidence: "URLSession.shared.data(from:)"),
        Row(name: "NIO ByteBuffer read", source: """
            func channelRead(buffer: inout ByteBuffer) {
                if let line = buffer.readString(length: 4) { sink(line) }
            }
            """, kind: .networkBytes, evidence: "readString"),
        Row(name: "workbook cell, through case let — SwiftExcelFunctions withRegex", source: """
            private static func withRegex(_ args: [CellValue], caseArgument: Int = 2) -> CellValue {
                guard case .text(let text) = args[0].resolved,
                      case .text(let pattern) = args[1].resolved else { return .error(.value) }
                let expression = try? NSRegularExpression(pattern: sink(pattern))
                return .bool(expression != nil && !text.isEmpty)
            }
            """, kind: .documentCell, evidence: "args: [CellValue]"),
        Row(name: "decode of file bytes", source: """
            func load(url: URL) throws {
                let blob = try Data(contentsOf: url)
                let config = try JSONDecoder().decode(Config.self, from: blob)
                sink(config.pattern)
            }
            """, kind: .fileBytes, evidence: "Data(contentsOf:)"),
    ]

    @Test("each source kind is recognised in real source", arguments: rows)
    func sourceKinds(_ row: Row) throws {
        let found = try trace(row.source)
        #expect(found?.kind == row.kind)
        #expect(found?.evidence == row.evidence)
    }

    // MARK: - Propagation steps, from source text

    @Test("a binding chain is followed, nearest binding first")
    func chain() throws {
        let found = try trace("""
            func f(arguments: [String: AnyCodable]?) {
                let raw = arguments?["p"]?.stringValue ?? ""
                let trimmed = raw
                var pattern = trimmed
                sink(pattern)
            }
            """)
        #expect(found?.path == ["pattern", "trimmed", "raw"])
        #expect(found?.kind == .mcpArgument)
    }

    @Test("interpolation, concatenation and a method call carry the source, not directly", arguments: [
        #"sink("^\(raw)$")"#,
        #"sink("^" + raw)"#,
        #"sink(raw.replacingOccurrences(of: "*", with: ".*"))"#,
        #"sink(flag ? raw : "x")"#,
    ])
    func indirect(line: String) throws {
        let found = try trace("""
            func f(args: [CellValue], flag: Bool) {
                guard case .text(let raw) = args[1] else { return }
                \(line)
            }
            """)
        #expect(found?.kind == .documentCell)
        #expect(found?.isDirect == false)
    }

    @Test("optional binding, try, await, force unwrap and a conversion keep it direct", arguments: [
        "if let v = env { sink(v) }",
        "guard let v = env else { return }; sink(v)",
        "sink(try String(env!))",
        "sink(await Int(env ?? 0))",
    ])
    func direct(line: String) throws {
        let found = try trace("""
            func f() async throws {
                let env = ProcessInfo.processInfo.environment["X"]
                \(line)
            }
            """)
        #expect(found?.kind == .environment)
        // `??` combines two values, so the last row is the source but not *only* the source.
        #expect(found?.isDirect == !line.contains("??"))
    }

    @Test("a for-in element of an external collection is external")
    func forIn() throws {
        let found = try trace("""
            func f() {
                for argument in CommandLine.arguments { sink(argument) }
            }
            """)
        #expect(found?.kind == .commandLine)
        #expect(found?.path == ["argument"])
    }

    @Test("the latest binding of a name before the sink is the one used")
    func latestBindingWins() throws {
        #expect(try trace("""
            func f() {
                let p = getenv("X")
                let q = p
                sink(q)
                let p = "literal"
            }
            """)?.kind == .environment)
        #expect(try trace("""
            func f() {
                let p = getenv("X")
                let p = "literal"
                sink(p)
            }
            """) == nil)
    }

    @Test("a plain parameter is reported as a parameter, with its index")
    func parameter() throws {
        let found = try derivation("""
            func compile(_ text: String, pattern: String) {
                let lowered = pattern.lowercased()
                sink(lowered)
            }
            """)
        #expect(found == .parameter(ExternalInput.Parameter(name: "pattern", type: "String", index: 1), path: ["lowered"]))
    }

    // MARK: - Stated limits

    @Test("a nested function's bindings and parameters are its own")
    func nestedFunctionIsAnotherFunction() throws {
        #expect(try derivation("""
            func outer(arguments: [String: AnyCodable]?) {
                func inner(value: String) { sink(value) }
            }
            """) == .parameter(ExternalInput.Parameter(name: "value", type: "String", index: 0), path: []))
    }

    @Test("a callee's result is not traced across the call")
    func crossFunction() throws {
        #expect(try trace("""
            func f(arguments: [String: AnyCodable]?) {
                let raw = arguments?["p"]?.stringValue ?? ""
                let pattern = helper(raw)
                sink(pattern)
            }
            """) == nil)
    }

    @Test("reassignment after the declaration is not followed")
    func reassignment() throws {
        #expect(try trace("""
            func f() {
                var pattern = "literal"
                pattern = getenv("X")
                sink(pattern)
            }
            """) == nil)
    }

    @Test("a callback's parameters are not sources")
    func callbackParameters() throws {
        #expect(try trace("""
            func f(url: URL) {
                URLSession.shared.dataTask(with: url) { data, _, _ in sink(data) }
            }
            """) == nil)
    }

    @Test("an untyped req without a server framework import is not a request")
    func reqWithoutVapor() throws {
        #expect(try trace("""
            func f() { handle { req in sink(req.query) } }
            """) == nil)
    }

    @Test("a binding whose own initialiser holds the sink does not resolve to itself")
    func ownInitialiser() throws {
        #expect(try derivation("""
            func f(pattern: String) {
                let pattern = sink(pattern)
            }
            """) == .parameter(ExternalInput.Parameter(name: "pattern", type: "String", index: 0), path: []))
    }
}

/// Finds the first `sink(…)` call's first argument.
private final class SinkFinder: SyntaxVisitor {
    var argument: ExprSyntax?

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if argument == nil,
           node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "sink",
           let first = node.arguments.first {
            argument = first.expression
        }
        return .visitChildren
    }
}
