import Foundation
import Testing
@testable import QualityGateCore
@testable import SafetyAuditor
@testable import ServerSurface

/// `security.bind-all-interfaces` and `security.listener-auth-optional`: the first rules that
/// read the server-surface inventory. Fixtures are the portfolio's real shapes —
/// `AHandlerThatAnyoneCanCall.md` §5, reconciled with `AHandlerSaysWhoMayCallIt.md` per
/// `TheGateIsNotYetAggressive.md` §2.1.
@Suite("Server surface rules")
struct ServerSurfaceRuleTests {

    static let bind = "security.bind-all-interfaces"
    static let auth = "security.listener-auth-optional"

    private func audit(_ source: String) async throws -> CheckResult {
        try await SafetyAuditor().auditSource(source, fileName: "Sources/Server/Server.swift", configuration: Configuration())
    }

    private func findings(_ result: CheckResult, _ rule: String) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId == rule }
    }

    private func audit(files: [(path: String, source: String)], targets: [TargetTypeMap.Target] = [],
                       configuration: Configuration = Configuration()) -> SafetyAuditor.ServerSurfaceOutcome {
        SafetyAuditor.auditServerSurface(
            sources: files, targets: TargetTypeMap(targets: targets), configuration: configuration)
    }

    // MARK: - bind-all-interfaces

    /// `(source, severity, line)` — one finding each; `nil` severity means clean.
    static let bindCases: [(name: String, source: String, severity: Diagnostic.Severity?, line: Int)] = [
        ("hard-coded at the bind (SwiftMCPServer)", """
            func start() async throws {
                let bootstrap = ServerBootstrap(group: group)
                let channel = try await bootstrap.bind(host: "0.0.0.0", port: 8080).get()
            }
            """, .error, 3),
        ("loopback", """
            func start() async throws {
                channel = try await ServerBootstrap(group: g).bind(host: "127.0.0.1", port: 0).get()
            }
            """, nil, 0),
        ("operator-supplied", """
            func start() async throws {
                _ = try await ServerBootstrap(group: g).bind(host: host, port: port).get()
            }
            """, nil, 0),
        ("initialiser default (SwiftCLIKit SSHServer)", """
            struct SSHServer {
                let host: String
                public init(host: String = "0.0.0.0", port: Int = 2222) { self.host = host }
                func run() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: port).get() }
            }
            """, .warning, 3),
        ("@Option default (IconquerServer)", """
            struct ServerCommand {
                @Option(help: "Host to bind to.") var host: String = "0.0.0.0"
                func run() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: 1).get() }
            }
            """, .warning, 2),
        ("argument to a listener in the same file", """
            func start() async throws {
                let bootstrap = ServerBootstrap(group: group)
                let server = TournamentWebSocketServer(host: "0.0.0.0", port: p)
            }
            """, .warning, 3),
        ("argument in a file with no listener", """
            func start() async throws {
                let server = TournamentWebSocketServer(host: "0.0.0.0", port: p)
            }
            """, nil, 0),
        ("comparison (geo-audit URLValidator)", """
            func isBlocked(_ host: String) -> Bool {
                let bootstrap = ServerBootstrap(group: group)
                if host == "0.0.0.0" || host.hasPrefix("0.") { return true }
                return false
            }
            """, nil, 0),
        ("array literal (the gate's allow-list)", """
            let bootstrap = ServerBootstrap(group: group)
            let allowedHTTPHosts: [String] = ["localhost", "127.0.0.1", "0.0.0.0"]
            """, nil, 0),
        ("NWListener hostPort ::", """
            import Network
            func start() throws {
                parameters.requiredLocalEndpoint = .hostPort(host: "::", port: port)
                let listener = try NWListener(using: parameters)
            }
            """, .error, 3),
        ("NWListener with no endpoint", """
            import Network
            func start() throws {
                let listener = try NWListener(using: .tcp, on: 8080)
            }
            """, .warning, 3),
        ("BSD sockets, INADDR_ANY (swiftMoE)", """
            func start() throws {
                var addr = sockaddr_in()
                addr.sin_addr.s_addr = INADDR_ANY.bigEndian
                guard listen(serverFD, 5) == 0 else { return }
            }
            """, .error, 3),
        ("BSD sockets, loopback", """
            func start() throws {
                var addr = sockaddr_in()
                addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
                guard listen(serverFD, 5) == 0 else { return }
            }
            """, nil, 0),
        ("doc comment", """
            /// - host: The address to bind to. Defaults to "0.0.0.0".
            func start() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: 1).get() }
            """, nil, 0),
    ]

    @Test("bind-all-interfaces: each shape", arguments: bindCases.map(\.name))
    func bindCase(name: String) async throws {
        let fixture = try #require(Self.bindCases.first { $0.name == name })
        let found = findings(try await audit(fixture.source), Self.bind)
        guard let severity = fixture.severity else {
            #expect(found.isEmpty, "\(name): \(found.map(\.message))")
            return
        }
        #expect(found.count == 1)
        #expect(found.first?.severity == severity)
        #expect(found.first?.lineNumber == fixture.line)
        #expect(found.first?.message.contains("[CWE-1327]") == true)
    }

    /// A constant is not a quoted literal, and the message should not dress it as one.
    @Test("bind-all-interfaces: the wildcard constant is named as written")
    func posixMessage() async throws {
        let fixture = try #require(Self.bindCases.first { $0.name == "BSD sockets, INADDR_ANY (swiftMoE)" })
        let found = findings(try await audit(fixture.source), Self.bind)
        #expect(found.map(\.message) == [
            "Listener bound to INADDR_ANY, every interface, by a constant in the socket address: a caller "
                + "cannot narrow it without editing this code. [CWE-1327]",
        ])
    }

    /// VaultMCP: the insecure mode is loopback, the default is everything. The loopback arm is
    /// not the finding; the fallback is, and its acknowledgement is one sentence.
    @Test("bind-all-interfaces: a ternary's all-interfaces arm is flagged, in a package with a listener")
    func vaultBindAddress() {
        let outcome = audit(files: [
            ("Sources/VaultMCPWeb/WebOptions.swift", """
                func parse(_ values: [String: String], insecure: Bool) -> WebOptions {
                    WebOptions(bindAddress: insecure ? "127.0.0.1" : (values["--bind"] ?? "0.0.0.0"))
                }
                """),
            ("Sources/VaultMCPWebMain/main.swift",
             "let channel = try ServerBootstrap(group: group).bind(host: options.bindAddress, port: options.port).wait()"),
        ])
        let found = outcome.diagnostics.filter { $0.ruleId == Self.bind }
        #expect(found.map(\.filePath) == ["Sources/VaultMCPWeb/WebOptions.swift"])
        #expect(found.map(\.lineNumber) == [2])
        #expect(found.map(\.severity) == [.warning])
    }

    /// IconquerTournament: the orchestrator constructs the server in another file.
    @Test("bind-all-interfaces: an argument to a listener-owning type declared in another file")
    func listenerOwningTypeArgument() {
        let outcome = audit(files: [
            ("Sources/T/TournamentWebSocketServer.swift", """
                final class TournamentWebSocketServer {
                    init(host: String, port: Int) {}
                    func start() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: port).get() }
                }
                """),
            ("Sources/T/TournamentOrchestrator.swift",
             "func run() { let server = TournamentWebSocketServer(host: \"0.0.0.0\", port: port) }"),
        ])
        let found = outcome.diagnostics.filter { $0.ruleId == Self.bind }
        #expect(found.map(\.filePath) == ["Sources/T/TournamentOrchestrator.swift"])
    }

    @Test("bind-all-interfaces: a default in a package with no listener is not a bind")
    func defaultWithoutListener() async throws {
        let result = try await audit("struct ClientConfig { var host: String = \"0.0.0.0\" }")
        #expect(findings(result, Self.bind).isEmpty)
    }

    @Test("bind-all-interfaces: a library listener inherited through SwiftMCPServer is the library's finding, not the consumer's")
    func inheritedIsNotReported() async throws {
        let result = try await audit("import SwiftMCPServer\ntry await MCPServer.builder().tools(t).run()")
        #expect(findings(result, Self.bind).isEmpty)
    }

    @Test("bind-all-interfaces: a test target is not a deployment")
    func testTargetIgnored() {
        let outcome = audit(
            files: [("Tests/ServerTests/Fixture.swift",
                     "func s() throws { _ = try ServerBootstrap(group: g).bind(host: \"0.0.0.0\", port: 1).wait() }")],
            targets: [.init(name: "ServerTests", type: "test", path: "Tests/ServerTests")])
        #expect(outcome.diagnostics.filter { $0.ruleId == Self.bind }.isEmpty)
    }

    // MARK: - listener-auth-optional

    static let authCases: [(name: String, source: String, line: Int?)] = [
        ("authenticator defaulting to nil (SwiftMCPServer HTTPServerTransport)", """
            func start() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: 1).get() }
            init(port: UInt16, authenticator: APIKeyAuthenticator? = nil) {}
            """, 2),
        ("authMode defaulting to .none (SwiftCLIKit SSHConfiguration)", """
            func start() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: 1).get() }
            public init(maxSessions: Int = 10, authMode: AuthMode = .none) {}
            """, 2),
        ("no listener in the target", "init(port: UInt16, authenticator: APIKeyAuthenticator? = nil) {}", nil),
        ("author", """
            func start() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: 1).get() }
            init(author: String? = nil) {}
            """, nil),
        ("a client's outgoing credential (SwiftMCPClient)", """
            func start() async throws { _ = try await ServerBootstrap(group: g).bind(host: "127.0.0.1", port: 0).get() }
            init(authorization: AuthorizationProvider? = nil) {}
            """, nil),
        ("required, no default", """
            func start() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: 1).get() }
            init(authenticator: APIKeyAuthenticator) {}
            """, nil),
        ("environment switch (SwiftMCPServer MCP_AUTH_REQUIRED)", """
            func start() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: 1).get() }
            let authRequired = ProcessInfo.processInfo.environment["MCP_AUTH_REQUIRED"] != "false"
            """, 2),
        ("nil authenticator to a library listener (IconquerMCP)", """
            let httpTransport = HTTPServerTransport(port: port, authenticator: nil, oauthServer: nil)
            """, 1),
    ]

    @Test("listener-auth-optional: each shape", arguments: authCases.map(\.name))
    func authCase(name: String) async throws {
        let fixture = try #require(Self.authCases.first { $0.name == name })
        let found = findings(try await audit(fixture.source), Self.auth)
        guard let line = fixture.line else {
            #expect(found.isEmpty, "\(name): \(found.map(\.message))")
            return
        }
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.lineNumber == line)
        #expect(found.first?.message.contains("[CWE-1188]") == true)
    }

    @Test("listener-auth-optional: an environment switch names its variable and its default")
    func environmentMessage() async throws {
        let result = try await audit(Self.authCases[6].source)
        let message = try #require(findings(result, Self.auth).first?.message)
        #expect(message.contains("MCP_AUTH_REQUIRED"))
        #expect(message.contains("on unless"))
    }

    /// The SSH shape: the default and the socket are in different files of one target, and the
    /// answer must not depend on file order.
    @Test("listener-auth-optional: target-wide, not file-wide")
    func targetWide() {
        let targets: [TargetTypeMap.Target] = [
            .init(name: "SSH", type: "library", path: "Sources/SSH"),
            .init(name: "Other", type: "library", path: "Sources/Other"),
        ]
        let server = ("Sources/SSH/SSHServer.swift",
                      "func run() async throws { _ = try await ServerBootstrap(group: g).bind(host: host, port: 1).get() }")
        let same = audit(files: [("Sources/SSH/SSHConfiguration.swift", "public init(authMode: AuthMode = .none) {}"), server],
                         targets: targets)
        #expect(same.diagnostics.filter { $0.ruleId == Self.auth }.map(\.filePath) == ["Sources/SSH/SSHConfiguration.swift"])
        let other = audit(files: [("Sources/Other/SSHConfiguration.swift", "public init(authMode: AuthMode = .none) {}"), server],
                          targets: targets)
        #expect(other.diagnostics.filter { $0.ruleId == Self.auth }.isEmpty)
    }

    // MARK: - Acknowledgement, enabling, coverage

    @Test("A reasoned acknowledgement is recorded; a bare marker is not", arguments: [bind, auth])
    func acknowledgement(rule: String) async throws {
        let code = rule == Self.bind ? Self.bindCases[0].source : Self.authCases[0].source
        var lines = code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let line = rule == Self.bind ? 3 : 2
        lines.insert("// SECURITY: deployed behind the nginx proxy on roseclub, which terminates TLS and authenticates", at: line - 1)
        let accepted = try await audit(lines.joined(separator: "\n"))
        #expect(findings(accepted, rule).isEmpty)
        #expect(accepted.overrides.map(\.ruleId) == [rule])

        lines[line - 1] = "// SECURITY:"
        let bare = try await audit(lines.joined(separator: "\n"))
        #expect(findings(bare, rule).count == 1)
    }

    @Test("A rule absent from a non-empty enabledRules is silent, and the note with it")
    func enabledRules() {
        var configuration = Configuration()
        configuration.security.enabledRules = ["security.ssrf"]
        let outcome = audit(files: [("Sources/Server/Server.swift", Self.bindCases[0].source)],
                            configuration: configuration)
        #expect(outcome.diagnostics.isEmpty)
    }

    @Test("The coverage note states the inventory, zeros and acknowledgements included")
    func coverageNote() throws {
        let outcome = audit(files: [("Sources/Lib/A.swift", "let x = 1")])
        let note = try #require(outcome.diagnostics.first { $0.ruleId == "security.server-surface-coverage" })
        #expect(note.severity == .note)
        #expect(note.message == "security.server-surface examined 1 file · 0 listeners · 0 bound to all interfaces · "
            + "0 with authentication off by default · 0 handlers · 0 acknowledged")
    }
}
