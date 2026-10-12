import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// An entity is a file read.
///
/// `XMLDocument(data:options: [])` on macOS loads every external entity that does not need the
/// network — a document that declares `<!ENTITY x SYSTEM "file:///…">` gets that file's bytes as
/// its text — and no option on `XMLDocument` stops internal expansion. `XMLParser` refused both
/// in every configuration the probe could build. The safe state of the portfolio is an accident
/// of which class was reached for; these rules make it a checked one.
///
/// See `quality-gate-swift-project/plans/proposals/AnEntityIsAFileRead.md` §5. Test numbers in
/// the names are that section's.
@Suite("XML entities")
struct XMLEntityTests {

    private static let external = "security.xml-external-entities"
    private static let expansion = "security.xml-entity-expansion"

    private func audit(_ body: String, configuration: Configuration = Configuration()) async throws -> CheckResult {
        let code = """
            import Foundation
            func parse(parser: XMLParser, d: Data, u: URL, s: String, e: XMLElement, opts: XMLNode.Options, allow: Bool, p: UnsafePointer<CChar>, n: Int32) throws {
            \(body)
            }
            """
        return try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: configuration)
    }

    private func findings(_ result: CheckResult, _ rule: String) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId == rule }
    }

    // MARK: - External entities: XMLParser properties

    @Test("1. shouldResolveExternalEntities = true is an error")
    func resolveTrue() async throws {
        let found = findings(try await audit("parser.shouldResolveExternalEntities = true"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.lineNumber == 3)
    }

    @Test("2. shouldResolveExternalEntities = false is clean")
    func resolveFalse() async throws {
        #expect(findings(try await audit("parser.shouldResolveExternalEntities = false"), Self.external).isEmpty)
    }

    @Test("3. decided at runtime is not false")
    func resolveVariable() async throws {
        let found = findings(try await audit("parser.shouldResolveExternalEntities = allow"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("4. externalEntityResolvingPolicy = .always is an error")
    func policyAlways() async throws {
        let found = findings(try await audit("parser.externalEntityResolvingPolicy = .always"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("5. .noNetwork is an error — a local file is what XXE reads")
    func policyNoNetwork() async throws {
        let found = findings(try await audit("parser.externalEntityResolvingPolicy = .noNetwork"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("6. externalEntityResolvingPolicy = .never is clean")
    func policyNever() async throws {
        #expect(findings(try await audit("parser.externalEntityResolvingPolicy = .never"), Self.external).isEmpty)
        #expect(findings(try await audit(
            "parser.externalEntityResolvingPolicy = XMLParser.ExternalEntityResolvingPolicy.never"), Self.external).isEmpty)
    }

    // MARK: - External entities: XMLDocument

    @Test("7. XMLDocument(data:) with no options is an error naming the default")
    func documentNoOptions() async throws {
        let found = findings(try await audit("_ = try XMLDocument(data: d)"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.message.contains("default") == true)
        #expect(found.first?.message.contains("nodeLoadExternalEntitiesNever") == true)
    }

    @Test("8. options: [] is the default spelled out")
    func documentEmptyOptions() async throws {
        let found = findings(try await audit("_ = try XMLDocument(data: d, options: [])"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("9. .nodeLoadExternalEntitiesNever clears it")
    func documentNever() async throws {
        #expect(findings(try await audit(
            "_ = try XMLDocument(data: d, options: [.nodeLoadExternalEntitiesNever])"), Self.external).isEmpty)
    }

    @Test("10. contentsOf: with an unrelated option is an error")
    func documentContentsOf() async throws {
        let found = findings(try await audit(
            "_ = try XMLDocument(contentsOf: u, options: [.nodePreserveWhitespace])"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("11. Always on a parse is one diagnostic, not two")
    func documentAlwaysOnce() async throws {
        let found = findings(try await audit(
            "_ = try XMLDocument(xmlString: s, options: .nodeLoadExternalEntitiesAlways)"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("Never beside Always does not clear Always")
    func documentNeverAndAlways() async throws {
        let found = findings(try await audit(
            "_ = try XMLDocument(data: d, options: [.nodeLoadExternalEntitiesNever, .nodeLoadExternalEntitiesAlways])"),
            Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("12. XInclude with Never is clean")
    func documentXIncludeNever() async throws {
        #expect(findings(try await audit(
            "_ = try XMLDocument(data: d, options: [.documentXInclude, .nodeLoadExternalEntitiesNever])"),
            Self.external).isEmpty)
    }

    @Test("13. options the rule cannot see are a warning that says so")
    func documentOpaqueOptions() async throws {
        let found = findings(try await audit("_ = try XMLDocument(data: d, options: opts)"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("not visible") == true)
    }

    @Test("14. XMLDocument(rootElement:) parses nothing")
    func documentRootElement() async throws {
        let result = try await audit("_ = XMLDocument(rootElement: e)")
        #expect(findings(result, Self.external).isEmpty)
        #expect(findings(result, Self.expansion).isEmpty)
    }

    @Test("A qualified or .init spelling is the same call")
    func documentQualified() async throws {
        #expect(findings(try await audit("_ = try Foundation.XMLDocument(data: d)"), Self.external).count == 1)
        #expect(findings(try await audit("_ = try XMLDocument.init(data: d)"), Self.external).count == 1)
    }

    @Test("Always outside a parse call is an error on its own")
    func alwaysStandalone() async throws {
        let found = findings(try await audit("let o: XMLNode.Options = [.nodeLoadExternalEntitiesSameOriginOnly]"),
                             Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    // MARK: - External entities: libxml2

    @Test("15. XML_PARSE_NOENT is an error")
    func libxmlNoent() async throws {
        let found = findings(try await audit(
            "_ = xmlReadMemory(p, n, nil, nil, Int32(XML_PARSE_NOENT.rawValue))"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("Every DTD-loading flag is an error", arguments: [
        "XML_PARSE_DTDLOAD", "XML_PARSE_DTDATTR", "XML_PARSE_DTDVALID", "XML_PARSE_XINCLUDE",
    ])
    func libxmlFlags(flag: String) async throws {
        let found = findings(try await audit("let flags = \(flag).rawValue"), Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("16. XML_PARSE_NONET is clean")
    func libxmlNonet() async throws {
        let result = try await audit("_ = xmlReadMemory(p, n, nil, nil, Int32(XML_PARSE_NONET.rawValue))")
        #expect(findings(result, Self.external).isEmpty)
        #expect(findings(result, Self.expansion).isEmpty)
    }

    @Test("xmlSubstituteEntitiesDefault(1) is an error; (0) is clean")
    func substituteDefault() async throws {
        let on = findings(try await audit("_ = xmlSubstituteEntitiesDefault(1)"), Self.external)
        #expect(on.count == 1)
        #expect(on.first?.severity == .error)
        #expect(findings(try await audit("_ = xmlSubstituteEntitiesDefault(0)"), Self.external).isEmpty)
    }

    // MARK: - External entities: the delegate hook

    @Test("17. a resolver that returns bytes is a warning")
    func resolverReturnsBytes() async throws {
        let code = """
            final class D: NSObject, XMLParserDelegate {
                func parser(_ p: XMLParser, resolveExternalEntityName n: String, systemID: String?) -> Data? {
                    try? Data(contentsOf: URL(fileURLWithPath: systemID ?? ""))
                }
            }
            """
        let result = try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: Configuration())
        let found = findings(result, Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.lineNumber == 2)
    }

    @Test("18. a resolver that returns nil is clean", arguments: ["nil", "return nil"])
    func resolverReturnsNil(body: String) async throws {
        let code = """
            final class D: NSObject, XMLParserDelegate {
                func parser(_ p: XMLParser, resolveExternalEntityName n: String, systemID: String?) -> Data? {
                    \(body)
                }
            }
            """
        let result = try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: Configuration())
        #expect(findings(result, Self.external).isEmpty)
    }

    // MARK: - External entities: what the portfolio actually writes

    @Test("19. shouldProcessNamespaces is not an entity property")
    func namespaces() async throws {
        #expect(findings(try await audit("parser.shouldProcessNamespaces = true"), Self.external).isEmpty)
    }

    @Test("20. a plain XMLParser is clean under both rules")
    func plainParser() async throws {
        let result = try await audit("let parser = XMLParser(data: d)\n_ = parser.parse()")
        #expect(findings(result, Self.external).isEmpty)
        #expect(findings(result, Self.expansion).isEmpty)
    }

    // MARK: - Expansion

    @Test("21. XML_PARSE_HUGE is an error")
    func huge() async throws {
        let found = findings(try await audit("let flags = Int32(XML_PARSE_HUGE.rawValue)"), Self.expansion)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("22. a DOM parse with no DTD refusal is a warning for 776 and clean for 611")
    func domParseNoRefusal() async throws {
        let result = try await audit("_ = try XMLDocument(data: d, options: [.nodeLoadExternalEntitiesNever])")
        let found = findings(result, Self.expansion)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(findings(result, Self.external).isEmpty)
    }

    @Test("23. a DOCTYPE guard before the parse clears it")
    func domParseGuarded() async throws {
        let result = try await audit("""
                guard d.range(of: Data("<!DOCTYPE".utf8)) == nil else { throw CocoaError(.fileReadCorruptFile) }
                _ = try XMLDocument(data: d, options: [.nodeLoadExternalEntitiesNever])
            """)
        #expect(findings(result, Self.expansion).isEmpty)
    }

    @Test("An ENTITY check in an if that exits clears it")
    func domParseIfGuarded() async throws {
        let result = try await audit("""
                if s.contains("<!ENTITY") { return }
                _ = try XMLDocument(xmlString: s, options: [.nodeLoadExternalEntitiesNever])
            """)
        #expect(findings(result, Self.expansion).isEmpty)
    }

    @Test("24. the same guard after the parse does not")
    func domParseGuardAfter() async throws {
        let result = try await audit("""
                _ = try XMLDocument(data: d, options: [.nodeLoadExternalEntitiesNever])
                guard d.range(of: Data("<!DOCTYPE".utf8)) == nil else { throw CocoaError(.fileReadCorruptFile) }
            """)
        let found = findings(result, Self.expansion)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
    }

    // MARK: - Acknowledgement and configuration

    @Test("25. a reasoned acknowledgement records both rules and reports neither")
    func acknowledged() async throws {
        let result = try await audit("""
                // SECURITY: bundled resource compiled into the app, never user input
                _ = try XMLDocument(data: d)
            """)
        #expect(findings(result, Self.external).isEmpty)
        #expect(findings(result, Self.expansion).isEmpty)
        let recorded = result.overrides.filter { $0.ruleId == Self.external || $0.ruleId == Self.expansion }
        #expect(recorded.map(\.ruleId).sorted() == [Self.expansion, Self.external])
        #expect(recorded.allSatisfy { $0.lineNumber == 4 })
        #expect(recorded.allSatisfy { $0.justification == "bundled resource compiled into the app, never user input" })
    }

    @Test("a short acknowledgement is rejected and the error stands")
    func shortAcknowledgement() async throws {
        let result = try await audit("""
                // SECURITY: bundled resource
                _ = try XMLDocument(data: d)
            """)
        let found = findings(result, Self.external)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.message.contains("2 words") == true)
        #expect(result.overrides.filter { $0.ruleId == Self.external }.isEmpty)
    }

    @Test("26. an allow-list without the rules silences both")
    func disabled() async throws {
        var configuration = Configuration()
        configuration.security.enabledRules = ["security.hardcoded-secret"]
        let result = try await audit("""
                parser.shouldResolveExternalEntities = true
                _ = try XMLDocument(data: d)
                let flags = XML_PARSE_HUGE
            """, configuration: configuration)
        #expect(findings(result, Self.external).isEmpty)
        #expect(findings(result, Self.expansion).isEmpty)
    }

    @Test("27. a string literal is not syntax")
    func stringLiteral() async throws {
        let result = try await audit(#"let text = "shouldResolveExternalEntities = true XML_PARSE_HUGE XMLDocument(data: d)""#)
        #expect(findings(result, Self.external).isEmpty)
        #expect(findings(result, Self.expansion).isEmpty)
    }

    // MARK: - Coverage

    /// Silence must say what it examined. In the portfolio this line reads 9 XMLParser sites and
    /// nothing else, which is a statement; no line at all is not.
    @Test("the run states how many XML parse sites it examined")
    func coverageNote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-xml-coverage-\(UUID().uuidString)")
        let file = root.appendingPathComponent("Sources/App/Parse.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort temp cleanup
        try """
            import Foundation
            func a(d: Data) { _ = XMLParser(data: d) }
            func b(d: Data) { _ = XMLParser(data: d) }
            func c(d: Data) throws { _ = try XMLDocument(data: d) }
            func e(d: Data) throws {
                // SECURITY: the document is generated by this process and never read from outside
                _ = try XMLDocument(data: d, options: [.nodeLoadExternalEntitiesNever])
            }
            """.write(to: file, atomically: true, encoding: .utf8)
        var configuration = Configuration()
        configuration.projectRoot = root
        let result = try await SafetyAuditor().check(configuration: configuration)
        let note = try #require(result.diagnostics.first { $0.ruleId == "security.xml-coverage" })
        #expect(note.severity == .note)
        #expect(note.message == "security.xml examined 4 XML parse sites · 2 XMLParser · 2 XMLDocument · "
            + "0 libxml2 · 1 configured to load external entities · 1 acknowledged")
    }
}
