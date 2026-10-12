import Foundation
import Testing
@testable import QualityGateCore
@testable import ServerSurface

/// The inventory as a whole: its summary line, its stability, and its columns.
@Suite("Server surface: inventory")
struct InventorySummaryTests {

    static let sources: [(path: String, source: String)] = [
        ("Sources/Server/Transport.swift", """
            import NIOHTTP1
            struct Transport {
                init(port: Int, authenticator: Authenticator? = nil) {}
                func start() throws {
                    _ = try ServerBootstrap(group: g).bind(host: "0.0.0.0", port: 1).wait()
                }
                func dispatch(method: HTTPMethod, path: String) {
                    switch (method, path) {
                    case (.GET, "/health"): break
                    default: break
                    }
                }
            }
            """),
        ("Sources/App/routes.swift", """
            import Vapor
            func routes(_ app: Application) throws {
                app.get("health") { _ in "ok" }
                app.post("v1", "runway") { _ in "" }
            }
            """),
        ("Sources/Run/main.swift", "import Vapor\nlet app = try await Application.make(env)"),
        ("Tests/ServerTests/Fixture.swift",
         "func s() throws { _ = try ServerBootstrap(group: g).bind(host: \"0.0.0.0\", port: 1).wait() }"),
    ]

    static let targets = TargetTypeMap(targets: [
        .init(name: "Server", type: "library", path: "Sources/Server"),
        .init(name: "App", type: "library", path: "Sources/App"),
        .init(name: "Run", type: "executable", path: "Sources/Run"),
        .init(name: "ServerTests", type: "test", path: "Tests/ServerTests"),
    ])

    @Test("The summary counts listeners and handlers by framework, and what test targets held")
    func summary() {
        let inventory = ServerSurfaceInventory.build(sources: Self.sources, targets: Self.targets)
        #expect(inventory.summary == "examined 4 files · 2 listeners (vapor 1, nio 1) · "
            + "1 bound to all interfaces · 1 with authentication off by default · "
            + "3 handlers (vapor 2, nio 1) · 1 listener and 0 handlers in test targets not counted")
    }

    @Test("Zeros are printed: an empty inventory says what it looked at")
    func emptySummary() {
        let inventory = ServerSurfaceInventory.build(sources: [("Sources/Lib/A.swift", "let x = 1")])
        #expect(inventory.summary == "examined 1 file · 0 listeners · 0 bound to all interfaces · "
            + "0 with authentication off by default · 0 handlers")
    }

    @Test("The inventory does not depend on the order files arrive in")
    func orderIndependent() {
        let forward = ServerSurfaceInventory.build(sources: Self.sources, targets: Self.targets)
        let reversed = ServerSurfaceInventory.build(sources: Self.sources.reversed(), targets: Self.targets)
        #expect(forward == reversed)
    }

    @Test("The inventory round-trips through JSON")
    func jsonRoundTrip() throws {
        var inventory = ServerSurfaceInventory.build(sources: Self.sources, targets: Self.targets)
        inventory.handlers[0].columns[.bodyCeiling] = ColumnValue("16 KB — Vapor default")
        let data = try JSONEncoder().encode(inventory)
        let decoded = try JSONDecoder().decode(ServerSurfaceInventory.self, from: data)
        #expect(decoded == inventory)
    }

    /// A later rule adds a column without reshaping a row (`BytesFromOutsideNeedACeiling.md`
    /// §3.1, `TheBrowserSendsTheCookieForYou.md` §3.1).
    @Test("A column is set by key on a handler found by site")
    func columnExtensionPoint() throws {
        var inventory = ServerSurfaceInventory.build(sources: Self.sources, targets: Self.targets)
        let site = try #require(inventory.handlers.first { $0.route == "/v1/runway" }).site
        let updated = inventory.setColumn(.credential, to: ColumnValue("none"), forHandlerAt: site)
        #expect(updated)
        #expect(inventory.handlers.first { $0.site == site }?.columns == [.credential: ColumnValue("none")])
        let missed = inventory.setColumn(.credential, to: ColumnValue("none"),
                                         forHandlerAt: SourceSite(file: "nowhere", line: 1, column: 1))
        #expect(!missed)
    }

    @Test("Address literals classify", arguments: [
        ("0.0.0.0", HostAddressKind.allInterfaces), ("::", .allInterfaces), ("[::]", .allInterfaces),
        ("127.0.0.1", .loopback), ("127.0.0.53", .loopback), ("::1", .loopback), ("localhost", .loopback),
        ("LOCALHOST", .loopback), ("10.0.1.114", .specific), ("example.com", .specific),
    ])
    func addressKinds(literal: String, kind: HostAddressKind) {
        #expect(HostAddressKind.classify(literal) == kind)
    }
}
