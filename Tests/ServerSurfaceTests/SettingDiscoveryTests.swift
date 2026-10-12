import Foundation
import Testing
@testable import QualityGateCore
@testable import ServerSurface

/// Host and authentication settings: the facts `security.bind-all-interfaces` and
/// `security.listener-auth-optional` read.
@Suite("Server surface: settings")
struct SettingDiscoveryTests {

    static func only(_ source: String) -> ServerSurfaceInventory {
        ServerSurfaceInventory.build(sources: [("Sources/Server/Server.swift", source)])
    }

    // MARK: - Host settings

    /// `(source, kind, name, value, callee)` — exactly one setting each.
    static let hostSettings: [(source: String, kind: HostSetting.Kind, name: String, value: String, callee: String?)] = [
        // SwiftCLIKit SSHServer, IconquerTournament TournamentWebSocketServer
        ("public init(host: String = \"0.0.0.0\", port: Int = 2222) {}", .parameterDefault, "host", "0.0.0.0", nil),
        // IconquerServer ServerCommand
        ("struct C { @Option(help: \"Host to bind to.\") var host: String = \"0.0.0.0\" }",
         .propertyDefault, "host", "0.0.0.0", nil),
        // Vapor configuration
        ("func configure(_ app: Application) { app.http.server.configuration.hostname = \"0.0.0.0\" }",
         .assignment, "hostname", "0.0.0.0", nil),
        // IconquerTournament TournamentOrchestrator
        ("let server = TournamentWebSocketServer(host: \"0.0.0.0\", port: port)",
         .argument, "host", "0.0.0.0", "TournamentWebSocketServer"),
        // VaultMCP WebOptions: the fallback is the default, the loopback arm is the insecure mode
        ("let o = WebOptions(bindAddress: insecure ? \"127.0.0.1\" : (values[\"--bind\"] ?? \"0.0.0.0\"))",
         .argument, "bindAddress", "0.0.0.0", "WebOptions"),
        // a bind argument is a setting as well as a listener
        ("func s() throws { _ = try ServerBootstrap(group: g).bind(host: \"0.0.0.0\", port: 1).wait() }",
         .bindArgument, "host", "0.0.0.0", "bind"),
        ("func s() { parameters.requiredLocalEndpoint = .hostPort(host: \"::\", port: port) }",
         .bindArgument, "host", "::", "hostPort"),
    ]

    @Test("A host literal written in source is a setting", arguments: hostSettings.indices)
    func hostSetting(index: Int) throws {
        let fixture = Self.hostSettings[index]
        let inventory = Self.only(fixture.source)
        let allInterfaces = inventory.hostSettings.filter { $0.addressKind == .allInterfaces }
        #expect(allInterfaces.count == 1)
        let setting = try #require(allInterfaces.first)
        #expect(setting.kind == fixture.kind)
        #expect(setting.name == fixture.name)
        #expect(setting.value == fixture.value)
        #expect(setting.callee == fixture.callee)
    }

    /// geo-audit's `URLValidator` compares against the address to reject it; the gate's own
    /// allow-list holds it in an array. Neither chooses where anything listens.
    @Test("A literal that is compared, listed or documented is not a setting", arguments: [
        "func isPrivate(_ host: String) -> Bool { if host == \"0.0.0.0\" || host.hasPrefix(\"0.\") { return true }; return false }",
        "let allowedHTTPHosts: [String] = [\"localhost\", \"127.0.0.1\", \"0.0.0.0\"]",
        "/// - host: The address to bind to. Defaults to \"0.0.0.0\".\nlet x = 1",
        "var host: String = \"\"",
        "let message = \"listening on 0.0.0.0\"",
        "let hosts = [\"host\": \"0.0.0.0\"]",
    ])
    func notASetting(source: String) {
        #expect(Self.only(source).hostSettings.filter { $0.addressKind == .allInterfaces }.isEmpty)
    }

    @Test("A host argument records whether its file opens a listener")
    func argumentInListenerFile() throws {
        let inventory = Self.only("""
            func start() async throws {
                let bootstrap = ServerBootstrap(group: group)
                let server = Wrapper(host: "0.0.0.0")
            }
            """)
        let setting = try #require(inventory.hostSettings.first { $0.kind == .argument })
        #expect(setting.fileHasListener)
    }

    // MARK: - Auth settings

    static let authOff: [(source: String, kind: AuthSetting.Kind, names: [String], state: AuthSetting.State)] = [
        // SwiftMCPServer HTTPServerTransport
        ("init(port: UInt16, authenticator: APIKeyAuthenticator? = nil) {}",
         .parameterDefault, ["authenticator"], .off),
        ("init(port: UInt16, oauthServer: OAuthServer? = nil) {}", .parameterDefault, ["oauthServer"], .off),
        // SwiftCLIKit SSHConfiguration
        ("public init(maxSessions: Int = 10, authMode: AuthMode = .none) {}",
         .parameterDefault, ["authMode"], .off),
        ("init(authRequired: Bool = false) {}", .parameterDefault, ["authRequired"], .off),
        ("struct Config { var authenticator: Authenticator? = nil }", .propertyDefault, ["authenticator"], .off),
        // SwiftMCPServer MCPServer.setupAPIKeyAuth / APIKeyAuthenticator.fromEnvironment
        ("let authRequired = ProcessInfo.processInfo.environment[\"MCP_AUTH_REQUIRED\"] != \"false\"",
         .environmentFlag, ["authRequired"], .onUnlessDisabled),
        ("let authEnabled = ProcessInfo.processInfo.environment[\"AUTH_ENABLED\"] == \"true\"",
         .environmentFlag, ["authEnabled"], .offUnlessSet),
        ("let requireAuth = Environment.get(\"REQUIRE_AUTH\") == \"1\"",
         .environmentFlag, ["requireAuth"], .offUnlessSet),
    ]

    @Test("An authentication switch written in source is a setting", arguments: authOff.indices)
    func authSetting(index: Int) throws {
        let fixture = Self.authOff[index]
        let inventory = Self.only(fixture.source)
        #expect(inventory.authSettings.count == 1)
        let setting = try #require(inventory.authSettings.first)
        #expect(setting.kind == fixture.kind)
        #expect(setting.names == fixture.names)
        #expect(setting.state == fixture.state)
    }

    @Test("An environment flag records its variable")
    func environmentKey() throws {
        let inventory = Self.only(Self.authOff[5].source)
        #expect(inventory.authSettings.first?.environmentKey == "MCP_AUTH_REQUIRED")
    }

    /// The name list is narrow on purpose (`AHandlerThatAnyoneCanCall.md` §3.1): `author`,
    /// `authorization` — a client's outgoing credential — and an empty key list, which with
    /// `authRequired: true` rejects everyone, are not authentication left off.
    @Test("A name that is not an authenticator, or a default that is not off, is not a setting", arguments: [
        "init(author: String? = nil) {}",
        "init(authorization: AuthorizationProvider? = nil) {}",
        "init(authenticator: APIKeyAuthenticator) {}",
        "init(apiKeys: [String] = [], authRequired: Bool = true) {}",
        "init(authMode: AuthMode = .password) {}",
        "private var _authenticator: APIKeyAuthenticator? = nil",
        "let authenticator = try makeAuthenticator()",
        "let authRequired = true",
        "let region = ProcessInfo.processInfo.environment[\"AWS_REGION\"] ?? \"us-east-1\"",
    ])
    func notAnAuthSetting(source: String) {
        #expect(Self.only(source).authSettings.isEmpty)
    }

    @Test("An authenticator passed as nil to a listener type is an argument setting")
    func nilArgumentToKnownListener() throws {
        let inventory = Self.only("let server = SSHServer(configuration: SSHConfiguration(authMode: .none))")
        let setting = try #require(inventory.authSettings.first)
        #expect(setting.kind == .argument)
        #expect(setting.names == ["authMode"])
        #expect(setting.callee == "SSHConfiguration")
    }

    @Test("An authenticator passed to an unrelated call is not a setting")
    func nilArgumentToUnrelatedCall() {
        #expect(Self.only("let client = Client(authenticator: nil)").authSettings.isEmpty)
    }

    // MARK: - Listener authentication, target-wide

    /// The SSH shape: the default is in `SSHConfiguration.swift`, the socket in `SSHServer.swift`.
    @Test("A listener's authentication is decided by the settings in its target")
    func authenticationAcrossFiles() throws {
        let targets = TargetTypeMap(targets: [
            .init(name: "SwiftCLIKitSSH", type: "library", path: "Sources/SwiftCLIKitSSH"),
            .init(name: "Other", type: "library", path: "Sources/Other"),
        ])
        let sameTarget = ServerSurfaceInventory.build(sources: [
            ("Sources/SwiftCLIKitSSH/SSHConfiguration.swift", "public init(authMode: AuthMode = .none) {}"),
            ("Sources/SwiftCLIKitSSH/SSHServer.swift",
             "func run() throws { _ = try ServerBootstrap(group: g).bind(host: host, port: port).wait() }"),
        ], targets: targets)
        #expect(sameTarget.listeners.first?.authentication == .optionalByDefault(names: ["authMode"]))
        #expect(sameTarget.targetHasListener("SwiftCLIKitSSH"))

        let otherTarget = ServerSurfaceInventory.build(sources: [
            ("Sources/Other/SSHConfiguration.swift", "public init(authMode: AuthMode = .none) {}"),
            ("Sources/SwiftCLIKitSSH/SSHServer.swift",
             "func run() throws { _ = try ServerBootstrap(group: g).bind(host: host, port: port).wait() }"),
        ], targets: targets)
        #expect(otherTarget.listeners.first?.authentication == .notVisible)
        #expect(!otherTarget.targetHasListener("Other"))
    }

    @Test("An environment switch in the listener's target is reported on the listener")
    func environmentSwitchOnListener() throws {
        let inventory = ServerSurfaceInventory.build(sources: [
            ("Sources/Lib/Auth.swift",
             "let authRequired = ProcessInfo.processInfo.environment[\"MCP_AUTH_REQUIRED\"] != \"false\""),
            ("Sources/Lib/Transport.swift",
             "func s() throws { _ = try ServerBootstrap(group: g).bind(host: \"0.0.0.0\", port: 1).wait() }"),
        ])
        #expect(inventory.listeners.first?.authentication == .environmentSwitch(keys: ["MCP_AUTH_REQUIRED"]))
    }
}
