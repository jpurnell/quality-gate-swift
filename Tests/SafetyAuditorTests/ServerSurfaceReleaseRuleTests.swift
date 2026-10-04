import Foundation
import Testing
@testable import QualityGateCore
@testable import SafetyAuditor
@testable import ServerSurface

/// `security.bind-all-interfaces` and `security.listener-auth-optional` over SwiftMCPServer's
/// two generations. 5.0.0 binds loopback and made both the address and "no authentication"
/// things a caller writes down; 4.x binds every interface and offers no way to narrow it.
@Suite("Server surface rules: SwiftMCPServer 4.x and 5.x")
struct ServerSurfaceReleaseRuleTests {

    static let bind = "security.bind-all-interfaces"
    static let auth = "security.listener-auth-optional"
    static let coverage = "security.server-surface-coverage"
    static let file = "Sources/Server/main.swift"

    static func manifest(_ version: String) -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Consumer",
            dependencies: [.package(url: "https://github.com/jpurnell/SwiftMCPServer.git", from: "\(version)")],
            targets: [.executableTarget(name: "Server")]
        )
        """
    }

    static let four = PackageDependencies(manifest: manifest("4.4.1"))
    static let five = PackageDependencies(manifest: manifest("5.0.0"))

    private func audit(_ source: String, _ dependencies: PackageDependencies = five) -> SafetyAuditor.ServerSurfaceOutcome {
        SafetyAuditor.auditServerSurface(
            sources: [(Self.file, source)], targets: TargetTypeMap(targets: []),
            configuration: Configuration(), dependencies: dependencies)
    }

    private func findings(_ outcome: SafetyAuditor.ServerSurfaceOutcome, _ rule: String) -> [Diagnostic] {
        outcome.diagnostics.filter { $0.ruleId == rule }
    }

    static let reason = "// SECURITY: bound to loopback and reached only through the nginx proxy, which authenticates"

    // MARK: - bind-all-interfaces

    @Test("5.x: a builder that names no host binds loopback and is not reported")
    func builderDefault() {
        let outcome = audit("""
            import SwiftMCPServer
            try await MCPServer.builder().serverName("x").tools(handlers).run()
            """)
        #expect(findings(outcome, Self.bind).isEmpty)
        #expect(findings(outcome, Self.auth).isEmpty)
        #expect(findings(outcome, Self.coverage).map(\.message) == [
            "security.server-surface examined 1 file · 1 listener (swift-mcp-server 1) · 0 bound to all interfaces · "
                + "0 with authentication off by default · 0 handlers · SwiftMCPServer read as 5.x "
                + "(from: \"5.0.0\" in Package.swift): binds 127.0.0.1 unless source says otherwise; "
                + "--host at launch is not visible · 0 acknowledged",
        ])
    }

    static let listen = """
        import SwiftMCPServer
        try await MCPServer.builder()
            .serverName("x")
            .listen(host: "0.0.0.0")
            .run()
        """

    /// A warning, not an error: `--host` at launch overrides `listen(host:)`, so the literal is
    /// what the server binds *unless someone changes it* — a default, in PR #14's terms.
    @Test("5.x: listen(host: \"0.0.0.0\") on a builder is a default an operator can still change: a warning")
    func builderListen() {
        let found = findings(audit(Self.listen), Self.bind)
        #expect(found.map(\.severity) == [.warning])
        #expect(found.map(\.lineNumber) == [4])
        #expect(found.map(\.message) == [
            "'host' is \"0.0.0.0\", every interface, unless someone changes it — and in a package that opens a "
                + "listener, nobody decided. [CWE-1327]",
        ])
    }

    @Test("5.x: listen(host:) acknowledged with a reason is clean and recorded")
    func builderListenAcknowledged() {
        let outcome = audit(Self.listen.replacingOccurrences(
            of: "    .listen(", with: "    \(Self.reason)\n    .listen("))
        #expect(findings(outcome, Self.bind).isEmpty)
        #expect(outcome.overrides.map(\.ruleId) == [Self.bind])
        #expect(outcome.overrides.map(\.lineNumber) == [5])
    }

    @Test("5.x: a host that is not a literal is the operator's, and is not reported", arguments: [
        "try await MCPServer.builder().listen(host: options.host).run()",
        "try await MCPServer.builder().listen(host: \"127.0.0.1\").run()",
        "let transport = HTTPServerTransport(port: port, host: host, authentication: .apiKey(authenticator))",
    ])
    func configurable(source: String) {
        let outcome = audit("import SwiftMCPServer\n" + source)
        #expect(findings(outcome, Self.bind).isEmpty)
        #expect(outcome.inventory.boundToAllInterfaces.isEmpty)
    }

    /// The same shape, and so the same grade, as `TournamentWebSocketServer(host: "0.0.0.0")`
    /// in PR #14: an argument to a type that opens a listener, whose own parameter is how a
    /// caller narrows it.
    @Test("5.x: HTTPServerTransport(host: \"0.0.0.0\") is an argument that reaches a listener: a warning")
    func transportHost() {
        let outcome = audit("""
            import SwiftMCPServer
            let transport = HTTPServerTransport(
                port: 8443,
                host: "0.0.0.0",
                authentication: .apiKey(authenticator))
            """)
        let found = findings(outcome, Self.bind)
        #expect(found.map(\.severity) == [.warning])
        #expect(found.map(\.lineNumber) == [4])
        #expect(findings(outcome, Self.auth).isEmpty)
    }

    @Test("4.x: a consumer is recorded as inheriting the all-interfaces bind — the library's finding, counted here")
    func consumerFour() {
        let outcome = audit("""
            import SwiftMCPServer
            try await MCPServer.builder().serverName("x").tools(handlers).run()
            """, Self.four)
        #expect(findings(outcome, Self.bind).isEmpty)
        #expect(outcome.inventory.boundToAllInterfaces.map(\.construct) == ["MCPServer.builder"])
        #expect(findings(outcome, Self.coverage).map(\.message) == [
            "security.server-surface examined 1 file · 1 listener (swift-mcp-server 1) · 1 bound to all interfaces · "
                + "0 with authentication off by default · 0 handlers · SwiftMCPServer read as 4.x "
                + "(from: \"4.4.1\" in Package.swift): binds 0.0.0.0 and takes no host · 0 acknowledged",
        ])
    }

    @Test("4.x: a transport built by hand is recorded the same way, and its nil authenticator is still reported")
    func transportFour() {
        let outcome = audit("""
            import SwiftMCPServer
            let transport = HTTPServerTransport(port: port, authenticator: nil, oauthServer: nil)
            """, Self.four)
        #expect(findings(outcome, Self.bind).isEmpty)
        #expect(outcome.inventory.boundToAllInterfaces.map(\.construct) == ["HTTPServerTransport"])
        #expect(findings(outcome, Self.auth).map(\.lineNumber) == [2])
        #expect(findings(outcome, Self.auth).map(\.message) == [
            "HTTPServerTransport is constructed with 'authenticator', 'oauthServer' passed as nil, nil: it will "
                + "accept requests from anyone who can reach it — an insecure default whose consequence is missing "
                + "authentication (CWE-306). [CWE-1188]",
        ])
    }

    // MARK: - listener-auth-optional

    static let unauthenticatedTransport = """
        import SwiftMCPServer
        func serve() async throws {
            let transport = HTTPServerTransport(port: 8080, authentication: .unauthenticated)
        }
        """

    @Test("5.x: authentication: .unauthenticated on a transport is reported as authenticator: nil was")
    func transportUnauthenticated() {
        let found = findings(audit(Self.unauthenticatedTransport), Self.auth)
        #expect(found.map(\.severity) == [.warning])
        #expect(found.map(\.lineNumber) == [3])
        #expect(found.map(\.message) == [
            "HTTPServerTransport is constructed with 'authentication' passed as .unauthenticated: it will "
                + "accept requests from anyone who can reach it — an insecure default whose consequence is missing "
                + "authentication (CWE-306). [CWE-1188]",
        ])
    }

    @Test("5.x: an unauthenticated transport acknowledged with a reason is clean and recorded")
    func transportUnauthenticatedAcknowledged() {
        let outcome = audit(Self.unauthenticatedTransport.replacingOccurrences(
            of: "    let transport", with: "    \(Self.reason)\n    let transport"))
        #expect(findings(outcome, Self.auth).isEmpty)
        #expect(outcome.overrides.map(\.ruleId) == [Self.auth])
        #expect(outcome.overrides.map(\.justification) == [
            "bound to loopback and reached only through the nginx proxy, which authenticates",
        ])
        #expect(findings(outcome, Self.coverage).map { $0.message.hasSuffix(" · 1 acknowledged") } == [true])
    }

    @Test("5.x: a bare marker does not acknowledge an unauthenticated transport")
    func transportUnauthenticatedBareMarker() {
        let outcome = audit(Self.unauthenticatedTransport.replacingOccurrences(
            of: "    let transport", with: "    // SECURITY:\n    let transport"))
        #expect(findings(outcome, Self.auth).count == 1)
        #expect(outcome.overrides.isEmpty)
    }

    static let unauthenticatedBuilder = """
        import SwiftMCPServer
        try await MCPServer.builder()
            .serverName("x")
            .authentication(.unauthenticated)
            .run()
        """

    @Test("5.x: .authentication(.unauthenticated) on a builder is reported where it is written")
    func builderUnauthenticated() {
        let found = findings(audit(Self.unauthenticatedBuilder), Self.auth)
        #expect(found.map(\.severity) == [.warning])
        #expect(found.map(\.lineNumber) == [4])
        #expect(found.map(\.message) == [
            "An MCPServer.builder() chain is given authentication(.unauthenticated): it will "
                + "accept requests from anyone who can reach it — an insecure default whose consequence is missing "
                + "authentication (CWE-306). [CWE-1188]",
        ])
    }

    @Test("5.x: an unauthenticated builder acknowledged inside the chain is clean and recorded")
    func builderUnauthenticatedAcknowledged() {
        let outcome = audit(Self.unauthenticatedBuilder.replacingOccurrences(
            of: "    .authentication(", with: "    \(Self.reason)\n    .authentication("))
        #expect(findings(outcome, Self.auth).isEmpty)
        #expect(outcome.overrides.map(\.ruleId) == [Self.auth])
        #expect(outcome.overrides.map(\.lineNumber) == [5])
    }

    @Test("5.x: an enforcing authentication is clean", arguments: [
        "let transport = HTTPServerTransport(port: 8080, authentication: .apiKey(authenticator))",
        "let transport = HTTPServerTransport(port: 8080, authentication: .oauth(server))",
        "let transport = HTTPServerTransport(port: 8080, authentication: .apiKeyOrOAuth(authenticator, server))",
        "try await MCPServer.builder().authentication(.apiKey(authenticator)).run()",
        "try await MCPServer.builder().authenticator(authenticator).run()",
        "try await MCPServer.builder().oauthServer(server).run()",
    ])
    func authenticated(source: String) {
        let outcome = audit("import SwiftMCPServer\n" + source)
        #expect(findings(outcome, Self.auth).isEmpty)
        #expect(findings(outcome, Self.bind).isEmpty)
        #expect(outcome.inventory.authenticationOffByDefault.isEmpty)
    }

    @Test("A client's .authentication(.unauthenticated) is not a listener's")
    func notABuilder() {
        let outcome = audit("import SwiftMCPServer\nlet client = HTTPClient().authentication(.unauthenticated)")
        #expect(findings(outcome, Self.auth).isEmpty)
    }

    // MARK: - From disk

    /// The path the gate takes: `Package.swift` and `Package.resolved` read from the package
    /// root, with nothing resolved or built.
    @Test("A package run reads the release from the package root", arguments: [
        ("4.4.1", "4.4.3", 1, "SwiftMCPServer read as 4.x (from: \"4.4.1\" in Package.swift, 4.4.3 in Package.resolved): "
            + "binds 0.0.0.0 and takes no host"),
        ("5.0.0", "5.0.0", 0, "SwiftMCPServer read as 5.x (from: \"5.0.0\" in Package.swift, 5.0.0 in Package.resolved): "
            + "binds 127.0.0.1 unless source says otherwise; --host at launch is not visible"),
    ])
    func packageRun(requirement: String, pin: String, allInterfaces: Int, release: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qg-surface-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources/Server")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // silent: a leftover fixture in the temporary directory fails nothing
        try Self.manifest(requirement).write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
            { "pins" : [ { "identity" : "swiftmcpserver", "kind" : "remoteSourceControl",
              "location" : "https://github.com/jpurnell/SwiftMCPServer.git",
              "state" : { "revision" : "abc", "version" : "\(pin)" } } ], "version" : 3 }
            """.write(to: root.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        try "import SwiftMCPServer\ntry await MCPServer.builder().serverName(\"x\").run()\n"
            .write(to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        var configuration = Configuration()
        configuration.projectRoot = root
        let result = try await SafetyAuditor().check(configuration: configuration)
        // Two files: the walk reads `Package.swift` as the Swift source it is.
        #expect(result.diagnostics.filter { $0.ruleId == Self.coverage }.map(\.message) == [
            "security.server-surface examined 2 files · 1 listener (swift-mcp-server 1) · \(allInterfaces) bound to all "
                + "interfaces · 0 with authentication off by default · 0 handlers · \(release) · 0 acknowledged",
        ])
    }
}
