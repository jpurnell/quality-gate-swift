import Foundation
import Testing
@testable import QualityGateCore
@testable import ServerSurface

/// Handler discovery: Vapor routes with their group lineage, SwiftMCPServer registrations, and
/// hand-written NIO dispatch. Reference truth is LedgeOS `Routes.swift`, geo-audit's guarded
/// collections, SwiftMCPServer's `MCPServerHandler`, and the five builder-chain `main.swift`s.
@Suite("Server surface: handlers")
struct HandlerDiscoveryTests {

    static func inventory(_ sources: [(path: String, source: String)], guardTypes: Set<String> = []) -> ServerSurfaceInventory {
        ServerSurfaceInventory.build(sources: sources, guardTypes: guardTypes)
    }

    static func only(_ source: String, guardTypes: Set<String> = []) -> ServerSurfaceInventory {
        inventory([("Sources/App/routes.swift", source)], guardTypes: guardTypes)
    }

    static func rows(_ inventory: ServerSurfaceInventory) -> [String] {
        inventory.handlers.map { "\($0.method ?? "-") \($0.route)" }
    }

    // MARK: - Vapor

    /// LedgeOS `Routes.swift` at `e2c1a2b`, reduced: six routes, nothing in front of any.
    static let ledgeOS = """
        import Vapor

        public func routes(_ app: Application, concurrentProjections: Int = 2) throws {
            let limiter = ProjectionLimiter(limit: concurrentProjections)
            app.get("health") { _ in "ok" }
            app.get("v1", "roles") { _ in RoleCatalog.entries }
            app.get("v1", "correlation-baselines") { _ in
                DriverCorrelation.baselines.map(CorrelationBaseline.init)
            }
            app.get { _ -> Response in
                page(form: nil, result: "")
            }
            app.post { request async throws -> Response in
                let form = try request.content.decode(RunwayForm.self)
                return page(form: form, result: "")
            }
            app.post("v1", "runway") { request async throws -> Response in
                let payload = try request.content.decode(RunwayRequest.self)
                return try await project(payload, on: request, within: limiter)
            }
        }
        """

    @Test("LedgeOS: six routes, method and path, nothing in front")
    func ledgeOSRoutes() throws {
        let inventory = Self.only(Self.ledgeOS)
        #expect(Self.rows(inventory) == [
            "GET /health", "GET /v1/roles", "GET /v1/correlation-baselines",
            "GET /", "POST /", "POST /v1/runway",
        ])
        #expect(inventory.handlers.allSatisfy { $0.framework == .vapor && $0.kind == .route })
        #expect(inventory.handlers.allSatisfy { $0.auth.verdict == .none })
        #expect(inventory.handlers.map(\.site.line) == [5, 6, 7, 10, 13, 17])
    }

    @Test("A route shape is one row", arguments: [
        ("app.on(.DELETE, \"items\", \":id\") { req in \"\" }", "DELETE /items/:id"),
        ("app.grouped(\"v1\").get(\"roles\") { _ in \"\" }", "GET /v1/roles"),
        ("app.get(\"x\", use: handler)", "GET /x"),
        ("app.get(PathComponent(stringLiteral: name)) { _ in \"\" }", "GET /<dynamic>"),
        ("app.patch(\"items\", \":id\") { _ in \"\" }", "PATCH /items/:id"),
    ])
    func routeShape(statement: String, row: String) {
        let source = "import Vapor\nfunc routes(_ app: Application) throws {\n    \(statement)\n}"
        #expect(Self.rows(Self.only(source)) == [row])
    }

    /// geo-audit: Fluent's `.delete()`, `req.parameters.get`, and a query `.group(.or)` all share
    /// a name with a route method and none is a route.
    @Test("A call that only shares a route method's name is not a route", arguments: [
        "let x = array.get(3)",
        "try await database.schema(\"users\").delete()",
        "let id = req.parameters.get(\"auditID\", as: UUID.self)",
        "try await query.group(.or) { group in group.filter(\\.$a == 1) }.all()",
        "try await user.delete(on: req.db)",
    ])
    func notARoute(statement: String) {
        let source = "import Vapor\nfunc work(req: Request) async throws {\n    \(statement)\n}"
        #expect(Self.only(source).handlers.isEmpty)
    }

    @Test("A route in a file that does not import Vapor is not recognised")
    func vaporImportRequired() {
        #expect(Self.only("func routes(_ app: Application) { app.get(\"x\") { _ in \"\" } }").handlers.isEmpty)
    }

    /// `(lineage statement, expected verdict, guards, authenticators, middleware)`.
    static let lineages: [(code: String, verdict: HandlerAuthVerdict, guards: [String], authenticators: [String], middleware: [String])] = [
        ("app.grouped(User.guardMiddleware()).post(\"x\") { _ in \"\" }",
         .protected, ["User.guardMiddleware()"], [], []),
        ("app.grouped(UserAuthenticator()).post(\"x\") { _ in \"\" }",
         .authenticatorOnly, [], ["UserAuthenticator()"], []),
        ("let authed = app.grouped(User.sessionAuthenticator())\nauthed.post(\"x\") { _ in \"\" }",
         .authenticatorOnly, [], ["User.sessionAuthenticator()"], []),
        ("let a = app.grouped(UserToken.authenticator())\nlet g = a.grouped(User.guardMiddleware())\ng.post(\"x\") { _ in \"\" }",
         .protected, ["User.guardMiddleware()"], ["UserToken.authenticator()"], []),
        ("app.grouped(RequireAuthMiddleware()).post(\"x\") { _ in \"\" }",
         .unclassifiedMiddleware, [], [], ["RequireAuthMiddleware()"]),
        ("app.grouped(User.redirectMiddleware(path: \"/login\")).get(\"x\") { _ in \"\" }",
         .protected, ["User.redirectMiddleware(path: \"/login\")"], [], []),
        ("app.group(\"admin\") { admin in\n    admin.grouped(Admin.guardMiddleware()).delete(\"x\") { _ in \"\" }\n}",
         .protected, ["Admin.guardMiddleware()"], [], []),
    ]

    @Test("A route carries the group lineage in front of it", arguments: lineages.indices)
    func lineage(index: Int) throws {
        let fixture = Self.lineages[index]
        let source = "import Vapor\nfunc routes(_ app: Application) throws {\n\(fixture.code)\n}"
        let handler = try #require(Self.only(source).handlers.first)
        #expect(handler.auth.verdict == fixture.verdict)
        #expect(handler.auth.guards == fixture.guards)
        #expect(handler.auth.authenticators == fixture.authenticators)
        #expect(handler.auth.middleware == fixture.middleware)
    }

    @Test("A group closure carries its path prefix")
    func groupPrefix() {
        let source = """
            import Vapor
            func routes(_ app: Application) throws {
                app.group("admin") { admin in
                    admin.grouped(Admin.guardMiddleware()).delete("x") { _ in "" }
                }
            }
            """
        #expect(Self.rows(Self.only(source)) == ["DELETE /admin/x"])
    }

    @Test("A middleware the project names as a guard protects")
    func configuredGuard() throws {
        let source = "import Vapor\nfunc routes(_ app: Application) throws {\n    app.grouped(APIKeyGate()).post(\"x\") { _ in \"\" }\n}"
        #expect(Self.only(source).handlers.first?.auth.verdict == .unclassifiedMiddleware)
        let guarded = try #require(Self.only(source, guardTypes: ["APIKeyGate"]).handlers.first)
        #expect(guarded.auth.verdict == .protected)
        #expect(guarded.auth.guards == ["APIKeyGate()"])
    }

    @Test("A handler that requires an authenticated user protects itself", arguments: [
        "app.grouped(UserAuthenticator()).post(\"x\") { req in\n    let user = try req.auth.require(User.self)\n    return user.name\n}",
        "app.grouped(UserAuthenticator()).post(\"x\", use: create)\nfunc create(req: Request) throws -> String { try req.auth.require(User.self).name }",
    ])
    func requireInHandler(code: String) throws {
        let source = "import Vapor\nfunc routes(_ app: Application) throws {\n\(code)\n}"
        let handler = try #require(Self.only(source).handlers.first)
        #expect(handler.auth.requiresInHandler)
        #expect(handler.auth.verdict == .protected)
    }

    @Test("Application middleware applies to every route in the target, whatever the order")
    func applicationMiddleware() throws {
        let inventory = Self.inventory([
            ("Sources/App/routes.swift", "import Vapor\nfunc routes(_ app: Application) throws {\n    app.get(\"x\") { _ in \"\" }\n}"),
            ("Sources/App/configure.swift", "import Vapor\nfunc configure(_ app: Application) {\n    app.middleware.use(app.sessions.middleware)\n}"),
        ])
        let handler = try #require(inventory.handlers.first)
        #expect(handler.auth.applicationMiddleware == ["app.sessions.middleware"])
    }

    // MARK: - Route collections

    static let collection = (path: "Sources/App/Controllers/DashboardController.swift", source: """
        import Vapor
        struct DashboardController: RouteCollection {
            func boot(routes: RoutesBuilder) throws {
                let dashboard = routes.grouped("dashboard")
                dashboard.get(use: index)
                dashboard.post("refresh", use: refresh)
            }
            func index(req: Request) async throws -> View { try await req.view.render("d") }
            func refresh(req: Request) async throws -> Response { req.redirect(to: "/") }
        }
        """)

    @Test("A collection registered on a guarded group inherits its lineage and prefix, across files")
    func collectionInheritsLineage() throws {
        let inventory = Self.inventory([
            ("Sources/App/routes.swift", """
                import Vapor
                func routes(_ app: Application) throws {
                    let sessions = app.grouped(User.sessionAuthenticator())
                    let protected = sessions.grouped(User.guardMiddleware())
                    try protected.grouped("app").register(collection: DashboardController())
                }
                """),
            Self.collection,
        ])
        #expect(Self.rows(inventory) == ["GET /app/dashboard", "POST /app/dashboard/refresh"])
        let first = try #require(inventory.handlers.first)
        #expect(first.auth.lineageKnown)
        #expect(first.auth.guards == ["User.guardMiddleware()"])
        #expect(first.auth.authenticators == ["User.sessionAuthenticator()"])
        #expect(first.auth.verdict == .protected)
        #expect(first.site.file == Self.collection.path)
    }

    @Test("A collection registered nowhere has an unknown lineage, which is not an empty one")
    func collectionUnregistered() throws {
        let inventory = Self.inventory([Self.collection])
        let first = try #require(inventory.handlers.first)
        #expect(!first.auth.lineageKnown)
        #expect(first.auth.verdict == .unknown)
        #expect(Self.rows(inventory) == ["GET /dashboard", "POST /dashboard/refresh"])
    }

    @Test("A collection registered twice gets the weaker lineage and names the other site")
    func collectionRegisteredTwice() throws {
        let inventory = Self.inventory([
            ("Sources/App/routes.swift", """
                import Vapor
                func routes(_ app: Application) throws {
                    try app.grouped(User.guardMiddleware()).register(collection: DashboardController())
                    try app.register(collection: DashboardController())
                }
                """),
            Self.collection,
        ])
        let first = try #require(inventory.handlers.first)
        #expect(first.auth.guards.isEmpty)
        #expect(first.auth.verdict == .none)
        #expect(first.auth.otherRegistrations == [SourceSite(file: "Sources/App/routes.swift", line: 3, column: 9)])
    }

    // MARK: - SwiftMCPServer

    static let tools = """
        import SwiftMCPServer
        public struct RunwayTool: MCPToolHandler {
            public let tool = MCPTool(name: "ledger_runway", description: "Runway", inputSchema: schema)
            public func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult { .success(text: "") }
        }
        struct RecordTool: MCPToolHandler {
            let tool = MCPTool(
                name: "ijs_record_calibration",
                description: "Writes to the corpus",
                inputSchema: schema
            )
        }
        """

    @Test("Each MCPToolHandler is one tools/call row named for its tool")
    func mcpTools() {
        let inventory = Self.inventory([("Sources/Lib/Tools.swift", Self.tools)])
        #expect(Self.rows(inventory) == ["tools/call ledger_runway", "tools/call ijs_record_calibration"])
        #expect(inventory.handlers.allSatisfy { $0.kind == .mcpTool && $0.framework == .swiftMCPServer })
        #expect(inventory.handlers.allSatisfy { $0.auth.verdict == .none })
    }

    @Test("A builder chain with an authenticator protects every tool in the package")
    func mcpBuilderAuthenticator() {
        let inventory = Self.inventory([
            ("Sources/Lib/Tools.swift", Self.tools),
            ("Sources/Server/main.swift", """
                import SwiftMCPServer
                try await MCPServer.builder()
                    .authenticator(APIKeyAuthenticator.fromEnvironment())
                    .tools(allToolHandlers())
                    .run()
                """),
        ])
        #expect(inventory.handlers.allSatisfy { $0.auth.transport == ["authenticator"] })
        #expect(inventory.handlers.allSatisfy { $0.auth.verdict == .protected })
    }

    /// VaultMCP: the builder is a binding and the authenticator is attached in a helper that
    /// takes it as a parameter.
    @Test("An authenticator attached to a builder binding or parameter counts")
    func mcpBuilderBinding() {
        let inventory = Self.inventory([
            ("Sources/Lib/Tools.swift", Self.tools),
            ("Sources/Main/Main.swift", """
                import SwiftMCPServer
                func configureAuth(_ builder: MCPServerBuilder) {
                    builder.authenticator(APIKeyAuthenticator(keyStore: store))
                }
                func main() async throws {
                    let builder = MCPServer.builder()
                    configureAuth(builder)
                    builder.oauthServer(oauth)
                    try await builder.run()
                }
                """),
        ])
        #expect(inventory.handlers.allSatisfy { $0.auth.transport == ["authenticator", "oauthServer"] })
    }

    @Test("Providers, HTTP routes and SDK method handlers are rows", arguments: [
        ("struct ResourceProvider: MCPResourceProvider {}", "resources/read ResourceProvider", HandlerKind.mcpProvider),
        ("struct PromptProvider: MCPPromptProvider {}", "prompts/get PromptProvider", HandlerKind.mcpProvider),
        ("let feed = MCPHTTPRoute(pathPrefix: \"/cal\", requiresAuthentication: false) { req in .ok }",
         "- /cal", HandlerKind.mcpHTTPRoute),
        ("await server.withMethodHandler(CallTool.self) { request in try await call(request) }",
         "- CallTool", HandlerKind.mcpMethodHandler),
    ])
    func mcpOtherRows(source: String, row: String, kind: HandlerKind) throws {
        let inventory = Self.only("import SwiftMCPServer\nimport MCP\n" + source)
        #expect(Self.rows(inventory) == [row])
        #expect(inventory.handlers.first?.kind == kind)
    }

    @Test("An MCP HTTP route declared public says so")
    func mcpHTTPRoutePublic() throws {
        let inventory = Self.only("import SwiftMCPServer\nlet feed = MCPHTTPRoute(pathPrefix: \"/cal\", requiresAuthentication: false) { req in .ok }")
        let handler = try #require(inventory.handlers.first)
        #expect(handler.auth.declaredRequiresAuthentication == false)
        #expect(handler.auth.verdict == .declaredPublic)
    }

    // MARK: - Hand dispatch

    /// `MCPServerHandler.processRequest`, reduced.
    static let dispatcher = """
        import NIOCore
        import NIOHTTP1
        final class MCPServerHandler: ChannelInboundHandler {
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
            func processRequest(method: HTTPMethod, path: String) async {
                switch (method, path) {
                case (.GET, "/health"):
                    respond(.ok)
                case (.POST, "/mcp"):
                    await handle()
                case (.POST, "/authorize/consent"):
                    await consent()
                default:
                    respond(.notFound)
                }
            }
        }
        """

    @Test("Each case of a (method, path) switch in an NIOHTTP1 file is a row")
    func handDispatch() {
        let inventory = Self.only(Self.dispatcher)
        let cases = inventory.handlers.filter { $0.kind == .dispatchCase }
        #expect(cases.map { "\($0.method ?? "-") \($0.route)" } == ["GET /health", "POST /mcp", "POST /authorize/consent"])
        #expect(cases.allSatisfy { $0.framework == .nio })
        #expect(cases.map(\.site.line) == [7, 9, 11])
    }

    @Test("The same switch without NIOHTTP1 is not dispatch")
    func handDispatchNeedsNIO() {
        let source = Self.dispatcher.replacingOccurrences(of: "import NIOHTTP1\n", with: "")
        #expect(Self.only(source).handlers.filter { $0.kind == .dispatchCase }.isEmpty)
    }

    /// VaultMCPWeb routes with `if request.path == …`. Pinned as a miss so a reader of the table
    /// knows the row is absent, not clean (`AHandlerSaysWhoMayCallIt.md` §3.6).
    @Test("Dispatch written as a chain of if is a known miss")
    func ifChainIsAKnownMiss() {
        let source = """
            import NIOHTTP1
            func route(_ request: Request) {
                if request.path == "/x" {
                    guard request.method == .POST else { return }
                }
            }
            """
        #expect(Self.only(source).handlers.isEmpty)
    }

    @Test("A channelRead on a handler a server bootstrap installs is a row; one it does not is not")
    func channelHandlers() {
        let inventory = Self.inventory([
            ("Sources/Server/Server.swift", """
                import NIOCore
                func start() async throws {
                    let bootstrap = ServerBootstrap(group: group)
                        .childChannelInitializer { channel in
                            channel.pipeline.addHandler(SessionHandler())
                        }
                    _ = try await bootstrap.bind(host: host, port: port).get()
                }
                """),
            ("Sources/Server/SessionHandler.swift", """
                final class SessionHandler: ChannelInboundHandler {
                    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
                }
                final class ClientHandler: ChannelInboundHandler {
                    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
                }
                """),
        ])
        #expect(inventory.handlers.map { "\($0.kind.rawValue) \($0.route)" } == ["channel-handler SessionHandler"])
    }

    @Test("A WebSocket upgrade is a row")
    func webSocketUpgrade() throws {
        let inventory = Self.only("""
            import NIOWebSocket
            func start() {
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                    upgradePipelineHandler: { channel, _ in channel.pipeline.addHandler(WebSocketHandler()) }
                )
            }
            """)
        let handler = try #require(inventory.handlers.first { $0.kind == .webSocketUpgrade })
        #expect(handler.framework == .nio)
        #expect(handler.route == "WebSocketHandler")
    }
}
