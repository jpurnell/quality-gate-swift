import Foundation
import Testing
@testable import QualityGateCore
@testable import ServerSurface

/// Listener discovery, against shapes reduced from the portfolio's real servers.
///
/// `ServerBootstrap.bind` is SwiftMCPServer's `HTTPServerTransport`; the host default resolved
/// through an initialiser is SwiftCLIKit's `SSHServer`; `NWListener` with a loopback endpoint is
/// SwiftWebAuthn's `CaptureHTTP`; `Application.make` is LedgeOS.
@Suite("Server surface: listeners")
struct ListenerDiscoveryTests {

    static func inventory(
        _ sources: [(path: String, source: String)],
        targets: [TargetTypeMap.Target] = []
    ) -> ServerSurfaceInventory {
        ServerSurfaceInventory.build(sources: sources, targets: TargetTypeMap(targets: targets))
    }

    static func only(_ source: String) -> ServerSurfaceInventory {
        inventory([("Sources/Server/Server.swift", source)])
    }

    // MARK: - Where it binds

    /// Each fixture opens one listener; the binding is what source says about the address.
    static let bindings: [(name: String, source: String, construct: String, framework: ServerFramework, host: HostBinding)] = [
        ("hard-coded all interfaces", """
            import NIOPosix
            func start() async throws {
                let bootstrap = ServerBootstrap(group: group)
                let channel = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
            }
            """, "ServerBootstrap.bind", .nio, .literal("0.0.0.0", .allInterfaces)),
        ("hard-coded loopback", """
            func start() async throws {
                let bootstrap = ServerBootstrap(group: group)
                channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            }
            """, "ServerBootstrap.bind", .nio, .literal("127.0.0.1", .loopback)),
        ("IPv6 any", """
            func start() throws { _ = try ServerBootstrap(group: g).bind(host: "::", port: 1).wait() }
            """, "ServerBootstrap.bind", .nio, .literal("::", .allInterfaces)),
        ("operator-supplied", """
            func start(options: Options) throws {
                let bootstrap = ServerBootstrap(group: group)
                let channel = try bootstrap.bind(host: options.bindAddress, port: options.port).wait()
            }
            """, "ServerBootstrap.bind", .nio, .expression("options.bindAddress", defaultValue: nil)),
        ("NWListener with a loopback endpoint", """
            import Network
            func start() throws {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
                let listener = try NWListener(using: parameters)
            }
            """, "NWListener", .network, .literal("127.0.0.1", .loopback)),
        ("NWListener with no endpoint", """
            import Network
            func start() throws {
                let listener = try NWListener(using: .tcp, on: 8080)
            }
            """, "NWListener", .network,
            .frameworkDefault(.allInterfaces, note: "NWListener with no requiredLocalEndpoint accepts on every interface")),
        ("NWListener on a Unix socket", """
            import Network
            func start() throws {
                let parameters = NWParameters()
                parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
                listener = try NWListener(using: parameters)
            }
            """, "NWListener", .network, .unixSocket),
        ("Vapor with no hostname", """
            import Vapor
            let app = try await Application.make(environment)
            """, "Application.make", .vapor,
            .frameworkDefault(.loopback, note: "Vapor binds 127.0.0.1 unless --hostname or configuration.hostname says otherwise")),
        ("SwiftMCPServer builder", """
            import SwiftMCPServer
            try await MCPServer.builder()
                .serverName("Example")
                .tools(allToolHandlers())
                .run()
            """, "MCPServer.builder", .swiftMCPServer,
            .inherited(library: "SwiftMCPServer", kind: .allInterfaces,
                       note: "HTTPServerTransport binds 0.0.0.0 and the builder cannot set the address")),
    ]

    @Test("A listener records where it binds", arguments: bindings.map(\.name))
    func binding(name: String) throws {
        let fixture = try #require(Self.bindings.first { $0.name == name })
        let inventory = Self.only(fixture.source)
        #expect(inventory.listeners.count == 1)
        let listener = try #require(inventory.listeners.first)
        #expect(listener.construct == fixture.construct)
        #expect(listener.framework == fixture.framework)
        #expect(listener.host == fixture.host)
    }

    @Test("A bind records its port and its line")
    func portAndLine() throws {
        let inventory = Self.only(Self.bindings[0].source)
        let listener = try #require(inventory.listeners.first)
        #expect(listener.port == "Int(port)")
        #expect(listener.site == SourceSite(file: "Sources/Server/Server.swift", line: 4, column: 29))
    }

    /// SwiftCLIKit's `SSHServer`: the bind names a stored property; the initialiser's default is
    /// what a caller of `SSHServer()` gets.
    @Test("A host expression resolves to its initialiser default, across files of one type")
    func hostDefaultThroughInitialiser() throws {
        let inventory = Self.inventory([
            ("Sources/SSH/SSHServer.swift", """
                public struct SSHServer {
                    public let host: String
                    public init(
                        host: String = "0.0.0.0",
                        port: Int = 2222
                    ) {
                        self.host = host
                    }
                }
                """),
            ("Sources/SSH/SSHServer+Run.swift", """
                extension SSHServer {
                    func run() async throws {
                        let bootstrap = ServerBootstrap(group: group)
                        let serverChannel = try await bootstrap.bind(host: host, port: port).get()
                    }
                }
                """),
        ])
        let listener = try #require(inventory.listeners.first)
        #expect(listener.owningType == "SSHServer")
        #expect(listener.host == .expression("host", defaultValue: HostDefault(
            value: "0.0.0.0", kind: .allInterfaces,
            site: SourceSite(file: "Sources/SSH/SSHServer.swift", line: 4, column: 24))))
        #expect(inventory.listenerOwningTypes == ["SSHServer"])
    }

    @Test("A host expression naming another type's property stays unresolved")
    func hostDefaultInAnotherType() throws {
        let inventory = Self.inventory([
            ("Sources/server/ServerCommand.swift", """
                struct ServerCommand: AsyncParsableCommand {
                    @Option(help: "Host to bind to.")
                    var host: String = "0.0.0.0"
                    func run() async throws { try await WebSocketServer(host: host, port: port).start() }
                }
                """),
            ("Sources/Server/WebSocketServer.swift", """
                final class WebSocketServer {
                    let address: String
                    init(host: String, port: Int) { self.address = host }
                    func start() async throws {
                        let bootstrap = ServerBootstrap(group: group)
                        _ = try await bootstrap.bind(host: address, port: port).get()
                    }
                }
                """),
        ])
        let listener = try #require(inventory.listeners.first)
        #expect(listener.host == .expression("address", defaultValue: nil))
        #expect(inventory.listenerOwningTypes == ["WebSocketServer"])
    }

    @Test("A Vapor hostname assigned anywhere in the package is the listener's address")
    func vaporHostnameAssignment() throws {
        let inventory = Self.inventory([
            ("Sources/Run/main.swift", """
                import Vapor
                let app = try await Application.make(env)
                try configure(app)
                """),
            ("Sources/App/configure.swift", """
                import Vapor
                func configure(_ app: Application) throws {
                    app.http.server.configuration.hostname = "0.0.0.0"
                }
                """),
        ])
        let listener = try #require(inventory.listeners.first)
        #expect(listener.host == .literal("0.0.0.0", .allInterfaces))
    }

    // MARK: - Library listeners

    @Test("A SwiftMCPServer transport constructed with no authenticator is a listener that says so")
    func transportWithNilAuthenticator() throws {
        let inventory = Self.only("""
            import SwiftMCPServer
            func serve() async throws {
                let httpTransport = HTTPServerTransport(
                    port: port,
                    authenticator: nil,
                    oauthServer: nil,
                    serverName: serverName
                )
            }
            """)
        let listener = try #require(inventory.listeners.first)
        #expect(inventory.listeners.count == 1)
        #expect(listener.construct == "HTTPServerTransport")
        #expect(listener.authentication == .explicitlyNone(names: ["authenticator", "oauthServer"]))
        #expect(inventory.authSettings.map(\.kind) == [.argument])
        #expect(inventory.authSettings.first?.names == ["authenticator", "oauthServer"])
        #expect(inventory.authSettings.first?.state == .off)
    }

    @Test("Inside the package that declares the transport, its own bind is the listener")
    func libraryTypeDeclaredHere() throws {
        let inventory = Self.inventory([
            ("Sources/Lib/HTTPServerTransport.swift", """
                public actor HTTPServerTransport {
                    func start() async throws {
                        let bootstrap = ServerBootstrap(group: group)
                        _ = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
                    }
                }
                """),
            ("Sources/Lib/MCPServer.swift", """
                func run() async throws {
                    let httpTransport = HTTPServerTransport(port: port, authenticator: authenticator)
                }
                """),
        ])
        #expect(inventory.listeners.map(\.construct) == ["ServerBootstrap.bind"])
    }

    @Test("Connecting is not listening", arguments: [
        "let channel = try await ClientBootstrap(group: g).connect(host: \"0.0.0.0\", port: 1).get()",
        "let connection = NWConnection(host: \"127.0.0.1\", port: 80, using: .tcp)",
        "let url = URL(string: \"http://0.0.0.0:8080\")",
    ])
    func clientsAreNotListeners(source: String) {
        #expect(Self.only(source).listeners.isEmpty)
    }

    // MARK: - Targets

    @Test("A listener in a test target is recorded, and its target is not a listener target")
    func testTargetListener() throws {
        let inventory = Self.inventory(
            [("Tests/ServerTests/Fixture.swift", """
                func start() throws { _ = try ServerBootstrap(group: g).bind(host: "0.0.0.0", port: 1).wait() }
                """)],
            targets: [TargetTypeMap.Target(name: "ServerTests", type: "test", path: "Tests/ServerTests")])
        let listener = try #require(inventory.listeners.first)
        #expect(listener.inTestTarget)
        #expect(listener.target == "ServerTests")
        #expect(inventory.listenerTargets.isEmpty)
        #expect(inventory.productionListeners.isEmpty)
    }

    @Test("A file no target claims belongs to the anonymous target")
    func anonymousTarget() {
        let inventory = Self.only(Self.bindings[0].source)
        #expect(inventory.listenerTargets == [ServerSurfaceInventory.anonymousTarget])
        #expect(inventory.targetHasListener(nil))
    }
}
