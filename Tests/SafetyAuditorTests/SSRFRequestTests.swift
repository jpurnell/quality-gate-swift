import Foundation
import Testing
@testable import QualityGateCore
@testable import SafetyAuditor

/// A URL is not a request.
///
/// `security.ssrf` used to report every `URL(string:)` whose argument was not a literal — 60
/// sites across the portfolio, 59 of them acknowledged, most of them a URL that was parsed and
/// never fetched. A forged request needs a request: the rule now reports a URL built from
/// non-literal input **that reaches a call which opens a connection**, with no question asked
/// about its host in between. Displayed, stored, returned and markup-only URLs are not reported.
///
/// See `quality-gate-swift-project/plans/proposals/AURLIsNotARequest.md`.
@Suite("SSRF needs a request")
struct SSRFRequestTests {

    static let rule = "security.ssrf"

    /// The line `body` starts on once ``wrapped(_:)`` has put it in a function.
    static let bodyLine = 6

    private static func wrapped(_ body: String) -> String {
        """
        import Foundation
        struct Client {
            let session: URLSession
            static let host = "api.example.com"
            func run(input: String, base: String, path: String, id: Int, allowed: Set<String>) async throws {
        \(body)
            }
        }
        """
    }

    private func findings(_ source: String) async throws -> [Diagnostic] {
        try await SafetyAuditor().auditSource(source, fileName: "test.swift", configuration: Configuration())
            .diagnostics.filter { $0.ruleId == Self.rule }
    }

    private func inBody(_ body: String) async throws -> [Diagnostic] {
        try await findings(Self.wrapped(body))
    }

    private func across(_ files: [(path: String, source: String)]) -> [Diagnostic] {
        SafetyAuditor.auditRequestFlow(sources: files, configuration: Configuration())
            .diagnostics.filter { $0.ruleId == Self.rule }
    }

    // MARK: - Sinks

    @Test("A built URL handed to URLSession is reported on the construction, naming sink and input")
    func sessionDataFrom() async throws {
        let found = try await inBody("""
                guard let url = URL(string: input) else { return }
                _ = try await session.data(from: url)
            """)
        let finding = try #require(found.first)
        #expect(found.count == 1)
        #expect(finding.lineNumber == Self.bodyLine)
        #expect(finding.severity == .warning)
        #expect(finding.message.contains("data(from:)"))
        #expect(finding.message.contains("input"))
        #expect(finding.message.contains("line \(Self.bodyLine + 1)"))
        #expect(finding.message.contains("[CWE-918]"))
        #expect(finding.suggestedFix?.contains("host") == true)
    }

    @Test("Every URLSession request method is a sink", arguments: [
        "session.dataTask(with: url).resume()",
        "_ = try await session.download(from: url)",
        "session.downloadTask(with: url).resume()",
        "_ = try await session.upload(for: URLRequest(url: url), from: Data())",
        "session.uploadTask(with: URLRequest(url: url), from: Data()).resume()",
        "_ = try await session.bytes(from: url)",
        "session.webSocketTask(with: url).resume()",
        "_ = try await URLSession.shared.data(for: URLRequest(url: url))",
    ])
    func sessionFamily(call: String) async throws {
        let found = try await inBody("""
                guard let url = URL(string: input) else { return }
                \(call)
            """)
        #expect(found.count == 1, "\(call)")
        #expect(found.first?.lineNumber == Self.bodyLine)
    }

    @Test("contentsOf: with a URL built from a string is a request", arguments: [
        "Data", "String", "NSData", "XMLParser",
    ])
    func contentsOfBuiltURL(type: String) async throws {
        let found = try await inBody("""
                guard let url = URL(string: input) else { return }
                _ = try \(type)(contentsOf: url)
            """)
        #expect(found.count == 1, "\(type)(contentsOf:)")
        #expect(found.first?.message.contains("\(type)(contentsOf:)") == true)
    }

    @Test("contentsOf: with a file URL by construction is not", arguments: [
        "_ = try Data(contentsOf: URL(fileURLWithPath: path))",
        "_ = try Data(contentsOf: URL(filePath: path))",
        "let file = URL(fileURLWithPath: base).appendingPathComponent(path); _ = try String(contentsOf: file)",
        "let file = URL(fileURLWithPath: path); _ = try NSData(contentsOf: file)",
    ])
    func contentsOfFileURL(statement: String) async throws {
        #expect(try await inBody("        \(statement)").isEmpty, "\(statement)")
    }

    @Test("AsyncHTTPClient: a request built from a string and executed is reported")
    func asyncHTTPClient() async throws {
        let found = try await inBody(#"""
                var request = HTTPClientRequest(url: "\(base)/v1/items")
                request.method = .GET
                _ = try await client.execute(request, timeout: .seconds(30))
            """#)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == Self.bodyLine)
        #expect(found.first?.message.contains("execute") == true)
    }

    @Test("execute and load are sinks only through the request they are given")
    func ordinaryWordsAreNotSinks() async throws {
        #expect(try await inBody("""
                guard let url = URL(string: input) else { return }
                store.execute(query)
                program.load(from: input)
                _ = url.absoluteString
            """).isEmpty)
    }

    @Test("WKWebView.load with a request built here is reported")
    func webViewLoad() async throws {
        let found = try await inBody("""
                guard let url = URL(string: input) else { return }
                webView.load(URLRequest(url: url))
            """)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("load") == true)
    }

    @Test("WebSocketKit and Network.framework connections are sinks")
    func otherConnections() async throws {
        #expect(try await inBody("""
                guard let url = URL(string: input) else { return }
                _ = WebSocket.connect(to: url.absoluteString, on: group) { _ in }
            """).count == 1)
        #expect(try await inBody("""
                guard let url = URL(string: input) else { return }
                let connection = NWConnection(to: .url(url), using: .tls)
            """).count == 1)
    }

    // MARK: - Reach

    @Test("One hop: the URL wrapped in a URLRequest that is then sent")
    func oneHopRequest() async throws {
        let found = try await inBody("""
                guard let url = URL(string: input) else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                let (data, _) = try await session.data(for: request)
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == Self.bodyLine)
        #expect(found.first?.message.contains("data(for:)") == true)
    }

    @Test("A URL that is returned is not a request")
    func returnedIsNotReported() async throws {
        #expect(try await findings("""
            import Foundation
            func make(_ string: String) -> URL? {
                URL(string: string)
            }
            func parse(_ string: String) throws -> URL {
                guard let url = URL(string: string) else { throw CocoaError(.fileNoSuchFile) }
                return url
            }
            """).isEmpty)
    }

    @Test("A URL stored in a property nobody requests is not a request")
    func storedIsNotReported() async throws {
        #expect(try await findings("""
            import Foundation
            struct Script {
                var file: URL?
                init(file: String) {
                    self.file = URL(string: file)
                }
                func render() -> String {
                    "<script src=\\"\\(file?.absoluteString ?? "")\\"></script>"
                }
            }
            """).isEmpty)
    }

    @Test("A URL written into markup is not a request")
    func markupIsNotReported() async throws {
        #expect(try await inBody(#"""
                guard let url = URL(string: input) else { return }
                let anchor = "<a href=\"\(url.absoluteString)\">\(url.host ?? "")</a>"
                print(anchor)
            """#).isEmpty)
    }

    @Test("A closure inside the function is still the function")
    func closureInsideFunction() async throws {
        let found = try await inBody("""
                guard let url = URL(string: input) else { return }
                let task = Task {
                    try await session.data(from: url)
                }
                _ = await task.result
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == Self.bodyLine)
    }

    @Test("URLs built in a closure and never requested are not reported")
    func mappedAndNeverRequested() async throws {
        #expect(try await inBody("""
                let urls = [input, base].compactMap { URL(string: $0) }
                print(urls.count)
            """).isEmpty)
    }

    @Test("URLs built in a closure and then fetched in a loop are reported")
    func mappedAndRequested() async throws {
        let found = try await inBody("""
                let urls = [input, base].compactMap { URL(string: $0) }
                for url in urls.prefix(3) {
                    _ = try await session.data(from: url)
                }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == Self.bodyLine)
    }

    @Test("geo-audit WebScraper.swift:83 — parsed in a closure, copied into an Array, fetched one hop away")
    func mappedCopiedAndPassedOn() async throws {
        func source(validating: Bool) -> String {
            """
            import Foundation
            struct WebScraper {
                let maxSubpages = 5
                private func scrapeSubpages(from internalURLs: [String], baseURL: URL) async -> [Data] {
                    let candidateURLs = internalURLs
                        .compactMap { URL(string: $0) }
                        .filter { url in url.path != "/" }
                    let urlsToScrape = Array(candidateURLs.prefix(maxSubpages))
                    guard !urlsToScrape.isEmpty else { return [] }
                    return await withTaskGroup(of: Data?.self, returning: [Data].self) { group in
                        for subpageURL in urlsToScrape {
                            group.addTask {
                                await self.scrapeSubpage(url: subpageURL)
                            }
                        }
                        return []
                    }
                }
                private func scrapeSubpage(url: URL) async -> Data? {
                    \(validating ? "guard let host = url.host, !isRestricted(host) else { return nil }" : "")
                    return try? await URLSession.shared.data(from: url).0
                }
            }
            """
        }
        let found = try await findings(source(validating: false))
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 6)
        #expect(found.first?.message.contains("scrapeSubpage(url:)") == true)
        #expect(try await findings(source(validating: true)).isEmpty)
    }

    // MARK: - Not dynamic

    @Test("Literal and constant URLs reaching a sink are not reported", arguments: [
        #"URL(string: "https://example.com/a")"#,
        #"URL(string: "https://\(Self.host)/a")"#,
        #"URL(string: "https://api.example.com/users/\(id)")"#,
        #"URL(string: "ws://127.0.0.1:\(id)/")"#,
        #"URL(string: "https://api.example.com?q=\(input)")"#,
    ])
    func literalAndConstant(construction: String) async throws {
        #expect(try await inBody("""
                guard let url = \(construction) else { return }
                _ = try await session.data(from: url)
            """).isEmpty, "\(construction)")
    }

    @Test("A literal that does not finish the host is still dynamic", arguments: [
        #"URL(string: "https://api.example.com\(input)")"#,
        #"URL(string: "https://\(input)/a")"#,
        #"URL(string: "\(base)/v1/messages")"#,
        #"URL(string: base + "/device")"#,
        #"URL(string: input, relativeTo: URL(string: "https://example.com"))"#,
    ])
    func unfinishedHost(construction: String) async throws {
        #expect(try await inBody("""
                guard let url = \(construction) else { return }
                _ = try await session.data(from: url)
            """).count == 1, "\(construction)")
    }

    @Test("A string that begins with a URL's own absoluteString and a path has that URL's host")
    func extendsAnExistingURL() async throws {
        // BusinessMathMarketData FREDProvider.swift:169 and EIAProvider.swift:115: the base is the
        // consumer's configured URL or a constant; what is appended starts a path.
        func source(_ string: String) -> String {
            """
            import Foundation
            struct Provider {
                private static let defaultBaseURL = "https://api.example.gov/v2"
                let configuration: Configuration
                func fetch(route: String, suffix: String) async throws -> Data {
                    let baseString = configuration.baseURL?.absoluteString ?? Self.defaultBaseURL
                    let routePath = route.hasPrefix("/") ? route : "/\\(route)"
                    guard let url = URLComponents(string: \(string))?.url else { return Data() }
                    return try await configuration.session.data(for: URLRequest(url: url)).0
                }
            }
            """
        }
        #expect(try await findings(source(#""\(baseString)/series/observations""#)).isEmpty)
        #expect(try await findings(source(#""\(baseString)\(routePath)/data""#)).isEmpty)
        #expect(try await findings(source(#"baseString + "/series""#)).isEmpty)
        // Nothing separates the host from what follows: the suffix can extend it.
        #expect(try await findings(source(#""\(baseString)\(suffix)""#)).count == 1)
        #expect(try await findings(source(#""\(baseString).\(suffix)/data""#)).count == 1)
    }

    @Test("Respelling the constructor does not hide the request")
    func urlComponentsRespelling() async throws {
        let found = try await inBody("""
                guard let url = URLComponents(string: input)?.url else { return }
                _ = try await session.data(from: url)
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == Self.bodyLine)
    }

    // MARK: - Validation

    @Test("A host check before the request clears it", arguments: [
        #"guard url.host == "api.example.com" else { return }"#,
        "guard let host = url.host, allowed.contains(host) else { return }",
        #"guard let host = url.host?.lowercased(), host.hasSuffix(".example.com") else { return }"#,
        "guard let host = url.host, !isRestricted(host) else { return }",
        #"switch url.host { case "a.example.com": break; default: return }"#,
    ])
    func hostCheckedBefore(check: String) async throws {
        #expect(try await inBody("""
                guard let url = URL(string: input) else { return }
                \(check)
                _ = try await session.data(from: url)
            """).isEmpty, "\(check)")
    }

    @Test("The same check after the request clears nothing")
    func hostCheckedAfter() async throws {
        let found = try await inBody("""
                guard let url = URL(string: input) else { return }
                _ = try await session.data(from: url)
                guard url.host == "api.example.com" else { return }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == Self.bodyLine)
    }

    @Test("Asking whether there is a host, or which scheme, is not asking which host", arguments: [
        #"guard url.scheme == "https", url.host != nil else { return }"#,
        "guard let host = url.host, !host.isEmpty else { return }",
        #"guard ["http", "https"].contains(url.scheme ?? "") else { return }"#,
    ])
    func presenceAndSchemeAreNotValidation(check: String) async throws {
        #expect(try await inBody("""
                guard let url = URL(string: input) else { return }
                \(check)
                _ = try await session.data(from: url)
            """).count == 1, "\(check)")
    }

    @Test("A validator in the same file clears; one that only reads the scheme does not")
    func validatorFunction() async throws {
        func source(_ validator: String) -> String {
            """
            import Foundation
            struct Generator {
                static func isAllowed(_ url: URL) -> Bool {
                    \(validator)
                }
                func send(_ text: String) async throws {
                    guard let url = URL(string: text), Self.isAllowed(url) else { return }
                    _ = try await URLSession.shared.data(for: URLRequest(url: url))
                }
            }
            """
        }
        #expect(try await findings(source(#"url.host == "anthropic.com""#)).isEmpty)
        #expect(try await findings(source(#"url.scheme == "https""#)).count == 1)
    }

    // MARK: - The join

    @Test("A type that requests its stored URL makes its initialiser a sink, across files")
    func initialiserOfRequestingType() {
        let stream = """
            import Foundation
            final class Stream {
                let url: URL
                init(url: URL) { self.url = url }
                func frames() {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 30
                    URLSession.shared.dataTask(with: request).resume()
                }
            }
            """
        let caller = """
            import Foundation
            func connect(_ text: String) {
                guard let url = URL(string: text) else { return }
                Stream(url: url).frames()
            }
            """
        let found = across([("Sources/Kit/Stream.swift", stream), ("Sources/App/Caller.swift", caller)])
        #expect(found.count == 1)
        #expect(found.first?.filePath == "Sources/App/Caller.swift")
        #expect(found.first?.lineNumber == 3)
        #expect(found.first?.message.contains("Stream(url:)") == true)
        #expect(found.first?.message.contains("Stream.swift:8") == true)
        // The same type, never handed a built URL, is nobody's finding.
        #expect(across([("Sources/Kit/Stream.swift", stream)]).isEmpty)
    }

    @Test("A wrapper that validates before requesting is not a sink; one that does not is")
    func validatingWrapper() {
        func files(validating: Bool) -> [(path: String, source: String)] {
            [("Sources/Net/Client.swift", """
                import Foundation
                struct Fetcher {
                    func fetch(url: URL) async throws -> Data {
                        \(validating ? "try Validator.validatePublic(url)" : "")
                        return try await URLSession.shared.data(from: url).0
                    }
                }
                enum Validator {
                    static func validatePublic(_ url: URL) throws {
                        guard let host = url.host?.lowercased(), !host.isEmpty else { throw CocoaError(.fileNoSuchFile) }
                        if isRestricted(host) { throw CocoaError(.fileNoSuchFile) }
                    }
                }
                """),
             ("Sources/Net/Crawler.swift", """
                import Foundation
                struct Crawler {
                    let fetcher: Fetcher
                    func crawl(_ line: String) async throws {
                        guard let url = URL(string: line) else { return }
                        _ = try await fetcher.fetch(url: url)
                    }
                }
                """)]
        }
        #expect(across(files(validating: true)).isEmpty)
        let found = across(files(validating: false))
        #expect(found.count == 1)
        #expect(found.first?.filePath == "Sources/Net/Crawler.swift")
        #expect(found.first?.lineNumber == 5)
    }

    @Test("A built URL stored where another method requests it is reported; stored and unrequested is not")
    func storedThenRequested() async throws {
        func source(requesting: Bool) -> String {
            """
            import Foundation
            final class Transport {
                var endpoint: URL?
                func receive(_ text: String, base: URL) {
                    self.endpoint = URL(string: text, relativeTo: base)?.absoluteURL
                }
                func send(_ body: Data) async throws {
                    guard let endpoint = endpoint else { return }
                    \(requesting ? "_ = try await URLSession.shared.upload(for: URLRequest(url: endpoint), from: body)" : "print(endpoint)")
                }
            }
            """
        }
        let found = try await findings(source(requesting: true))
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 5)
        #expect(try await findings(source(requesting: false)).isEmpty)
    }

    // MARK: - A returned URL

    @Test("A function that returns the URL it builds from its argument: the caller's argument decides")
    func producerFromParameter() async throws {
        func source(_ argument: String) -> String {
            """
            import Foundation
            enum Endpoints {
                static func parsed(_ string: String) -> URL? {
                    URL(string: string)
                }
            }
            func fetch(_ text: String) async throws {
                guard let url = Endpoints.parsed(\(argument)) else { return }
                _ = try await URLSession.shared.data(from: url)
            }
            """
        }
        let found = try await findings(source("text"))
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 8, "reported where the dynamic string enters")
        #expect(found.first?.message.contains("parsed(_:)") == true)
        #expect(found.first?.message.contains("`text`") == true)
        #expect(try await findings(source(#""https://example.com/a""#)).isEmpty)
    }

    @Test("A function that returns a URL built from its own input is reported there, once a caller requests it")
    func producerFromItsOwnInput() async throws {
        func source(requesting: Bool) -> String {
            """
            import Foundation
            enum Server {
                static func url() throws -> URL {
                    let string = ProcessInfo.processInfo.environment["SERVER"] ?? "http://127.0.0.1:3001/mcp"
                    guard let url = URL(string: string) else { throw CocoaError(.fileNoSuchFile) }
                    return url
                }
            }
            func probe() async throws {
                let server = try Server.url()
                \(requesting ? "_ = try await URLSession.shared.data(from: server)" : "print(server)")
            }
            """
        }
        let found = try await findings(source(requesting: true))
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 5)
        #expect(found.first?.message.contains("url()") == true)
        #expect(found.first?.message.contains("the environment") == true)
        #expect(try await findings(source(requesting: false)).isEmpty)
    }

    @Test("A producer that checks the host before returning is not one")
    func validatingProducer() async throws {
        #expect(try await findings("""
            import Foundation
            enum Validator {
                static func validated(_ string: String) -> URL? {
                    guard let url = URL(string: string) else { return nil }
                    guard url.host == "releases.example.com" else { return nil }
                    return url
                }
            }
            func check(_ text: String) async throws {
                guard let url = Validator.validated(text) else { return }
                _ = try await URLSession.shared.data(from: url)
            }
            """).isEmpty)
    }

    @Test("SwiftMCPClient ConformanceServerTests.swift:149 — an environment URL, returned, then connected to")
    func conformanceServerURL() {
        let found = across([
            ("Sources/MCPClient/Transport/StreamableHTTPTransport.swift", """
                import AsyncHTTPClient
                public actor StreamableHTTPTransport {
                    private let url: URL
                    public init(url: URL, openServerStream: Bool = true) {
                        self.url = url
                    }
                    public func send(_ data: Data) async throws {
                        var request = HTTPClientRequest(url: url.absoluteString)
                        request.method = .POST
                        _ = try await client.execute(request, timeout: connectionTimeout)
                    }
                }
                """),
            ("Tests/MCPClientTests/ConformanceServerTests.swift", """
                import Foundation
                import Testing
                struct ConformanceServerTests {
                    @Test func initialises() async throws {
                        let transport = StreamableHTTPTransport(url: try ConformanceServer.url())
                        try await transport.send(Data())
                    }
                }
                enum ConformanceServer {
                    static func url() throws -> URL {
                        let string = ProcessInfo.processInfo.environment["MCP_CONFORMANCE_SERVER"]
                            ?? "http://127.0.0.1:3001/mcp"
                        return try #require(URL(string: string), "MCP_CONFORMANCE_SERVER is not a URL")
                    }
                }
                """),
        ])
        #expect(found.count == 1)
        #expect(found.first?.filePath == "Tests/MCPClientTests/ConformanceServerTests.swift")
        #expect(found.first?.lineNumber == 13)
        #expect(found.first?.message.contains("StreamableHTTPTransport(url:)") == true)
    }

    @Test("Two producers with one name are both reported when the name's result is requested")
    func producersSharingAName() {
        func helper(_ type: String, _ variable: String) -> String {
            """
            import Foundation
            enum \(type) {
                static func url() throws -> URL {
                    let string = ProcessInfo.processInfo.environment["\(variable)"] ?? "http://127.0.0.1:3001/mcp"
                    return try #require(URL(string: string))
                }
            }
            func probe\(type)() async throws {
                _ = try await URLSession.shared.data(from: try \(type).url())
            }
            """
        }
        let found = across([
            ("Tests/ConformanceServerTests.swift", helper("ConformanceServer", "MCP_CONFORMANCE_SERVER")),
            ("Tests/StatelessEraServerTests.swift", helper("StatelessServer", "MCP_STATELESS_SERVER")),
        ])
        #expect(found.compactMap(\.filePath).sorted() == ["Tests/ConformanceServerTests.swift", "Tests/StatelessEraServerTests.swift"])
        #expect(found.map(\.lineNumber) == [5, 5])
    }

    @Test("swift-oauth DPoPClientTests.swift:17 — a test helper given literals, however its result is used")
    func testHelperGivenLiterals() async throws {
        #expect(try await findings("""
            import Foundation
            import Testing
            struct DPoPClientTests {
                private func url(_ string: String) throws -> URL {
                    try #require(URL(string: string))
                }
                @Test func fetches() async throws {
                    let endpoint = try url("https://api.example.com/resource")
                    _ = try await URLSession.shared.data(from: endpoint)
                }
            }
            """).isEmpty)
    }

    // MARK: - Severity

    @Test("A URL from request content that is fetched is an error and says where it came from")
    func requestContentIsAnError() async throws {
        let found = try await findings("""
            import Vapor
            func proxy(req: Request) async throws -> Response {
                guard let target = req.query[String.self, at: "u"], let url = URL(string: target) else {
                    throw Abort(.badRequest)
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                return Response(body: .init(data: data))
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.message.contains("HTTP request content") == true)
    }

    @Test("A URL from the command line that is fetched is the operator's: a warning that says so")
    func commandLineIsAWarning() async throws {
        let found = try await inBody("""
                guard let url = URL(string: CommandLine.arguments[1]) else { return }
                _ = try await session.data(from: url)
            """)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("the command line") == true)
    }

    // MARK: - Real sites (AURLIsNotARequest.md §4.2)

    @Test("Ignite Image.swift:42 and Link.swift:255 — parsed for markup, never requested")
    func igniteMarkup() async throws {
        #expect(try await findings("""
            import Foundation
            public struct Image {
                var path: URL?
                var description: String?
                public init(_ path: String, description: String? = nil) {
                    self.path = URL(string: path)
                    self.description = description
                }
                public init(decorative name: String) {
                    self.path = URL(string: name)
                    self.description = ""
                }
            }
            struct Link {
                var url: String
                private func renderStandardLink() -> Markup {
                    var linkAttributes = attributes.appending(classes: linkClasses)
                    guard let url = URL(string: url) else {
                        publishingContext.addWarning("One of your links uses an invalid URL.")
                        return Markup()
                    }
                    let path = publishingContext.linkPath(for: url)
                    linkAttributes.append(customAttributes: .init(name: "href", value: path))
                    return Markup(path)
                }
            }
            """).isEmpty)
    }

    @Test("swift-oauth ChallengeParsing.swift:61 — a server's pointer, parsed and not followed")
    func oauthChallengePointer() async throws {
        #expect(try await findings("""
            import Foundation
            struct Challenge {
                let realm: String?
                let resourceMetadata: URL?
                init(parameters: [String: String]) {
                    realm = parameters["realm"]
                    resourceMetadata = parameters["resource_metadata"].flatMap { URL(string: $0) }
                }
            }
            """).isEmpty)
    }

    @Test("CoverLetterWriter ClaudeClient.swift:121 — host compared, request returned")
    func coverLetterValidatedRequest() async throws {
        #expect(try await findings("""
            import Foundation
            struct ClaudeClient {
                let endpoint: String
                let apiKey: String
                func send(prompt: String) async throws -> Data {
                    let request = try buildRequest(prompt: prompt)
                    let (data, _) = try await URLSession.shared.data(for: request)
                    return data
                }
                private func buildRequest(prompt: String) throws -> URLRequest {
                    guard let url = URL(string: endpoint),
                          url.host == "api.anthropic.com" else {
                        throw LLMError.invalidResponse(body: "Invalid or unexpected API endpoint URL")
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    return request
                }
            }
            """).isEmpty)
    }

    @Test("quality-gate StandardsWatchCommand.swift:123 — allow-listed host, then fetched")
    func standardsWatchAllowList() async throws {
        #expect(try await findings("""
            import Foundation
            struct StandardsWatch {
                static let allowedHosts: Set<String> = ["www.ecfr.gov"]
                func fetchUpstream(for catalog: ControlCatalog) async throws -> String? {
                    guard catalog.source == "ecfr" else { return nil }
                    let resolved = catalog.sourceRef.replacingOccurrences(of: "{date}", with: Self.todayUTC())
                    guard let url = URL(string: resolved), let host = url.host, Self.allowedHosts.contains(host) else { return nil }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 15
                    let (data, _) = try await URLSession.shared.data(for: request)
                    return String(data: data, encoding: .utf8)
                }
            }
            """).isEmpty)
    }

    @Test("IconquerServer LiveSocketTests.swift:98 — a loopback literal with a port in it")
    func loopbackLiteralWithPort() async throws {
        #expect(try await findings(#"""
            import Foundation
            struct LiveServer {
                let port: Int
                func connect() async throws -> LiveClient {
                    let url = try #require(URL(string: "ws://127.0.0.1:\(port)/"))
                    let task = URLSession.shared.webSocketTask(with: url)
                    task.resume()
                    return LiveClient(task: task)
                }
            }
            """#).isEmpty)
    }

    @Test("endoscope ViewerModel.swift:78 — a typed URL, scheme-checked, streamed two types away")
    func endoscopeViewer() {
        let found = across([
            ("Sources/EndoscopeKit/Transport/MJPEGStream.swift", """
                import Foundation
                public final class MJPEGStream: NSObject {
                    private var session: URLSession?
                    public let url: URL
                    public init(url: URL) {
                        self.url = url
                        super.init()
                    }
                    public func frames() -> AsyncThrowingStream<EndoscopeFrame, Error> {
                        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
                            queue.addOperation { [self] in
                                let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
                                self.session = session
                                var request = URLRequest(url: url)
                                request.timeoutInterval = 30
                                session.dataTask(with: request).resume()
                            }
                        }
                    }
                }
                """),
            ("Sources/EndoscopeKit/Transport/MJPEGSession.swift", """
                import Foundation
                public struct MJPEGSession {
                    public let url: URL
                    public init(url: URL, policy: ReconnectPolicy = .default) {
                        self.url = url
                    }
                    public func events() -> AsyncStream<Event> {
                        AsyncStream { continuation in
                            Task {
                                for try await frame in MJPEGStream(url: url).frames() {
                                    continuation.yield(.frame(frame))
                                }
                            }
                        }
                    }
                }
                """),
            ("Sources/EndoscopeViewer/ViewerModel.swift", """
                import Foundation
                final class ViewerModel {
                    var urlString = ""
                    func connect() {
                        disconnect()
                        let allowedSchemes: Set<String> = ["http", "https"]
                        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
                              let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme),
                              url.host != nil else {
                            state = .failed("Invalid URL")
                            return
                        }
                        let session = MJPEGSession(url: url)
                        task = Task { for await event in session.events() { await self.apply(event) } }
                    }
                }
                """),
        ])
        #expect(found.count == 1)
        #expect(found.first?.filePath == "Sources/EndoscopeViewer/ViewerModel.swift")
        #expect(found.first?.lineNumber == 7)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("MJPEGSession(url:)") == true)
    }

    @Test("SwiftMCPClient HTTPSSETransport.swift:348 — the server names the endpoint the client posts to")
    func sseEndpointChosenByServer() async throws {
        let found = try await findings("""
            import Foundation
            public actor HTTPSSETransport {
                private let url: URL
                private var endpointURL: URL?
                public func send(_ data: Data) async throws {
                    guard let endpointURL = endpointURL, let client = httpClient else {
                        throw MCPError.connectionFailed(reason: "Not connected")
                    }
                    var response = try await post(data, to: endpointURL, on: client, forcingRefresh: false)
                    if response.status.code == 401 {
                        response = try await post(data, to: endpointURL, on: client, forcingRefresh: true)
                    }
                }
                private func post(
                    _ data: Data,
                    to endpointURL: URL,
                    on client: HTTPClient,
                    forcingRefresh: Bool
                ) async throws -> HTTPClientResponse {
                    var request = HTTPClientRequest(url: endpointURL.absoluteString)
                    request.method = .POST
                    request.body = .bytes(data)
                    do {
                        return try await client.execute(request, timeout: connectionTimeout)
                    } catch {
                        throw MCPError.connectionFailed(reason: error.localizedDescription)
                    }
                }
                private func read(events: [SSEEvent]) throws {
                    for event in events {
                        if event.event == "endpoint" {
                            guard let resolvedEndpoint = URL(
                                string: event.data, relativeTo: url
                            )?.absoluteURL else {
                                throw MCPError.connectionFailed(reason: "Invalid endpoint URL")
                            }
                            self.endpointURL = resolvedEndpoint
                        }
                    }
                }
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 32)
        #expect(found.first?.message.contains("event.data") == true)
        #expect(found.first?.message.contains("endpointURL") == true)
    }

    @Test("geo-audit SpecialFilesFetcher.swift:83 — every fetch goes through a client that validates first")
    func geoAuditValidatedClient() {
        #expect(across([
            ("Sources/WebScraper/HTTPClient.swift", """
                import Foundation
                public protocol HTTPClientProtocol: Sendable {
                    func fetch(url: URL) async throws -> HTTPResponse
                }
                public struct URLSessionHTTPClient: HTTPClientProtocol, Sendable {
                    public func fetch(url: URL) async throws -> HTTPResponse {
                        try URLValidator.validatePublicURL(url)
                        let (data, response) = try await URLSession.shared.data(from: url)
                        return HTTPResponse(statusCode: 200, body: data)
                    }
                }
                """),
            ("Sources/App/Services/NIOHTTPClient.swift", """
                import AsyncHTTPClient
                struct NIOHTTPClient: HTTPClientProtocol, Sendable {
                    private let client: HTTPClient
                    func fetch(url: URL) async throws -> HTTPResponse {
                        try URLValidator.validatePublicURL(url)
                        var request = HTTPClientRequest(url: url.absoluteString)
                        request.method = .GET
                        let response = try await client.execute(request, timeout: .seconds(30))
                        return HTTPResponse(statusCode: Int(response.status.code), body: Data())
                    }
                }
                """),
            ("Sources/WebScraper/URLValidator.swift", """
                import Foundation
                public enum URLValidator {
                    public static func validatePublicURL(_ url: URL) throws {
                        guard let scheme = url.scheme?.lowercased(),
                              scheme == "http" || scheme == "https" else {
                            throw ScraperError.unsafeURL(url.absoluteString, reason: "Only http and https schemes are allowed")
                        }
                        guard let host = url.host?.lowercased(), !host.isEmpty else {
                            throw ScraperError.unsafeURL(url.absoluteString, reason: "URL must have a host")
                        }
                        if isRestricted(host) {
                            throw ScraperError.unsafeURL(url.absoluteString, reason: "Requests to private or reserved addresses are not allowed")
                        }
                    }
                }
                """),
            ("Sources/WebScraper/SpecialFilesFetcher.swift", """
                import Foundation
                struct SpecialFilesFetcher {
                    let httpClient: any HTTPClientProtocol
                    private func fetchOptionalFile(baseURL: URL, path: String) async -> String? {
                        guard let fileURL = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
                            return nil
                        }
                        do {
                            let response = try await httpClient.fetch(url: fileURL)
                            return String(data: response.body, encoding: .utf8)
                        } catch {
                            return nil
                        }
                    }
                    private func fetchReferencedSitemaps(_ sitemapURLs: [String]) async -> [String: String] {
                        var results: [String: String] = [:]
                        await withTaskGroup(of: (String, String?).self) { group in
                            for urlString in sitemapURLs {
                                group.addTask {
                                    guard let url = URL(string: urlString) else { return (urlString, nil) }
                                    do {
                                        let response = try await self.httpClient.fetch(url: url)
                                        return (urlString, String(data: response.body, encoding: .utf8))
                                    } catch {
                                        return (urlString, nil)
                                    }
                                }
                            }
                        }
                        return results
                    }
                }
                """),
        ]).isEmpty)
    }

    @Test("endoscope main.swift:43 — top-level code, the tool's own argument, streamed")
    func endoscopeCommandLine() {
        let found = across([
            ("Sources/EndoscopeKit/Transport/MJPEGStream.swift", """
                import Foundation
                public final class MJPEGStream {
                    public let url: URL
                    public init(url: URL) { self.url = url }
                    public func frames() { URLSession.shared.dataTask(with: URLRequest(url: url)).resume() }
                }
                """),
            ("Sources/endoscope-cli/main.swift", """
                import Foundation
                let arguments = CommandLine.arguments
                let streamSchemes: Set<String> = ["http", "https"]
                if arguments.count >= 3, arguments[1] == "stream",
                   let url = URL(string: arguments[2]),
                   let scheme = url.scheme?.lowercased(), streamSchemes.contains(scheme),
                   url.host != nil {
                    let stream = MJPEGStream(url: url)
                    stream.frames()
                }
                """),
        ])
        #expect(found.count == 1)
        #expect(found.first?.filePath == "Sources/endoscope-cli/main.swift")
        #expect(found.first?.lineNumber == 5)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("the command line") == true)
    }

    // MARK: - Contract

    @Test("Negative control: one request and one parse is exactly one finding, on the request's URL")
    func negativeControl() async throws {
        let found = try await findings("""
            import Foundation
            func fetch(_ text: String) async throws {
                guard let url = URL(string: text) else { return }
                _ = try await URLSession.shared.data(from: url)
            }
            func make(_ text: String) -> URL? {
                URL(string: text)
            }
            """)
        #expect(found.map(\.lineNumber) == [3])
    }

    @Test("One URL sent to two sinks is one finding")
    func oneDefectOneDiagnostic() async throws {
        let found = try await inBody("""
                guard let url = URL(string: input) else { return }
                _ = try await session.data(from: url)
                _ = try Data(contentsOf: url)
            """)
        #expect(found.count == 1)
    }

    @Test("An acknowledgement on the construction still answers the finding")
    func acknowledgementOnConstruction() async throws {
        let result = try await SafetyAuditor().auditSource(Self.wrapped("""
                // SECURITY: the endpoint is the user's own camera, typed by them; no host allowlist exists to check it against.
                guard let url = URL(string: input) else { return }
                _ = try await session.data(from: url)
            """), fileName: "test.swift", configuration: Configuration())
        #expect(!result.diagnostics.contains { $0.ruleId == Self.rule })
        #expect(result.overrides.filter { $0.ruleId == Self.rule }.count == 1)
    }

    @Test("The rule is switched off by enabledRules")
    func disabled() async throws {
        var configuration = Configuration()
        configuration.security.enabledRules = ["security.eval-js"]
        let result = try await SafetyAuditor().auditSource(Self.wrapped("""
                guard let url = URL(string: input) else { return }
                _ = try await session.data(from: url)
            """), fileName: "test.swift", configuration: configuration)
        #expect(!result.diagnostics.contains { $0.ruleId == Self.rule })
    }

    @Test("The manifest describes a request, not a parse")
    func manifest() throws {
        let entry = try #require(SecurityRuleManifest.rules.first { $0.ruleId == Self.rule })
        #expect(entry.cwes == ["CWE-918"])
        #expect(entry.description.contains("request"))
        #expect(entry.lastReviewedDate == "2026-10-05")
    }
}
