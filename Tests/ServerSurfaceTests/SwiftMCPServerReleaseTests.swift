import Foundation
import Testing
@testable import QualityGateCore
@testable import ServerSurface

/// SwiftMCPServer 5.0.0 changed the facts the inventory encodes: the transport and the builder
/// bind `127.0.0.1` unless told otherwise, the address became a setting (`host:`,
/// `listen(host:)`, `--host`), and authentication became one required argument with a case
/// called `.unauthenticated`. A package may still resolve 4.x, where the bind is `0.0.0.0` and
/// nothing can narrow it — so both generations are pinned here, and so is how the inventory
/// tells them apart.
@Suite("Server surface: SwiftMCPServer 4.x and 5.x")
struct SwiftMCPServerReleaseTests {

    static func manifest(_ requirement: String) -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Consumer",
            dependencies: [
                .package(url: "https://github.com/apple/swift-nio.git", from: "2.60.0"),
                .package(\(requirement)),
            ],
            targets: [.executableTarget(name: "Consumer")]
        )
        """
    }

    static let url = "url: \"https://github.com/jpurnell/SwiftMCPServer.git\""
    static let four = PackageDependencies(manifest: manifest(url + ", from: \"4.4.1\""))
    static let five = PackageDependencies(manifest: manifest(url + ", from: \"5.0.0\""))

    static func resolved(_ version: String) -> String {
        """
        {
          "pins" : [
            { "identity" : "swift-nio", "kind" : "remoteSourceControl",
              "location" : "https://github.com/apple/swift-nio.git",
              "state" : { "revision" : "abc", "version" : "2.60.0" } },
            { "identity" : "swiftmcpserver", "kind" : "remoteSourceControl",
              "location" : "https://github.com/jpurnell/SwiftMCPServer.git",
              "state" : { "revision" : "def", "version" : "\(version)" } }
          ],
          "version" : 3
        }
        """
    }

    static func inventory(_ source: String, _ dependencies: PackageDependencies = .unknown) -> ServerSurfaceInventory {
        ServerSurfaceInventory.build(
            sources: [("Sources/Server/main.swift", "import SwiftMCPServer\n" + source)],
            dependencies: dependencies)
    }

    static let builderNote5 = "SwiftMCPServer 5 binds 127.0.0.1 unless listen(host:) or --host at launch says otherwise"
    static let transportNote5 = "HTTPServerTransport binds 127.0.0.1 unless host: is passed"
    static let builderNote4 = "SwiftMCPServer before 5.0.0 binds 0.0.0.0 and the builder cannot set the address"
    static let transportNote4 = "HTTPServerTransport before SwiftMCPServer 5.0.0 binds 0.0.0.0 and has no host parameter"

    // MARK: - 5.x: where it binds

    @Test("5.x: a builder that names no host is a loopback listener")
    func builderDefault() {
        let inventory = Self.inventory("try await MCPServer.builder().serverName(\"x\").tools(t).run()", Self.five)
        #expect(inventory.listeners.map(\.construct) == ["MCPServer.builder"])
        #expect(inventory.listeners.map(\.host) == [.frameworkDefault(.loopback, note: Self.builderNote5)])
        #expect(inventory.boundToAllInterfaces.isEmpty)
        #expect(inventory.hostSettings.isEmpty)
    }

    @Test("5.x: listen(host:) with an all-interfaces literal binds that literal, and is a host argument that reaches a listener")
    func builderListenLiteral() {
        let inventory = Self.inventory("""
            try await MCPServer.builder()
                .serverName("x")
                .listen(host: "0.0.0.0")
                .run()
            """, Self.five)
        #expect(inventory.listeners.map(\.host) == [.literal("0.0.0.0", .allInterfaces)])
        #expect(inventory.boundToAllInterfaces.map(\.construct) == ["MCPServer.builder"])
        #expect(inventory.hostSettings.map(\.kind) == [.argument])
        #expect(inventory.hostSettings.map(\.callee) == ["listen"])
        #expect(inventory.hostSettings.map(\.site.line) == [4])
        #expect(inventory.hostSettings.map(\.fileHasListener) == [true])
    }

    @Test("5.x: listen(host:) with a loopback literal is loopback by the caller's own word")
    func builderListenLoopback() {
        let inventory = Self.inventory("try await MCPServer.builder().listen(host: \"127.0.0.1\").run()", Self.five)
        #expect(inventory.listeners.map(\.host) == [.literal("127.0.0.1", .loopback)])
        #expect(inventory.boundToAllInterfaces.isEmpty)
    }

    @Test("5.x: listen(host:) with an expression is configurable, as a NIO bind(host:) is")
    func builderListenExpression() {
        let inventory = Self.inventory("try await MCPServer.builder().listen(host: options.host).run()", Self.five)
        #expect(inventory.listeners.map(\.host) == [.expression("options.host", defaultValue: nil)])
        #expect(inventory.listeners.map(\.host.isHardCoded) == [false])
        #expect(inventory.hostSettings.isEmpty)
    }

    @Test("5.x: listen(host:) on a name bound to the builder reaches the same listener")
    func builderBinding() {
        let inventory = Self.inventory("""
            func serve() async throws {
                let builder = MCPServer.builder()
                builder.listen(host: "::")
                try await builder.run()
            }
            """, Self.five)
        #expect(inventory.listeners.map(\.host) == [.literal("::", .allInterfaces)])
    }

    @Test("A listen(host:) that is not on a builder is not a builder's address")
    func unrelatedListen() {
        let inventory = Self.inventory("""
            try await MCPServer.builder().run()
            socketServer.listen(host: "0.0.0.0")
            """, Self.five)
        #expect(inventory.listeners.map(\.host) == [.frameworkDefault(.loopback, note: Self.builderNote5)])
        #expect(inventory.hostSettings.map(\.fileHasListener) == [false])
    }

    @Test("5.x: a transport with no host is a loopback listener")
    func transportDefault() {
        let inventory = Self.inventory(
            "let transport = HTTPServerTransport(port: 8080, authentication: .apiKey(authenticator))", Self.five)
        #expect(inventory.listeners.map(\.construct) == ["HTTPServerTransport"])
        #expect(inventory.listeners.map(\.host) == [.frameworkDefault(.loopback, note: Self.transportNote5)])
        #expect(inventory.boundToAllInterfaces.isEmpty)
    }

    @Test("5.x: a transport given a host literal binds it, and the literal is a host argument that reaches a listener")
    func transportLiteral() {
        let inventory = Self.inventory("""
            let transport = HTTPServerTransport(
                port: 8443,
                host: "0.0.0.0",
                authentication: .apiKey(authenticator))
            """, Self.five)
        #expect(inventory.listeners.map(\.host) == [.literal("0.0.0.0", .allInterfaces)])
        #expect(inventory.hostSettings.map(\.kind) == [.argument])
        #expect(inventory.hostSettings.map(\.callee) == ["HTTPServerTransport"])
        #expect(inventory.hostSettings.map(\.site.line) == [4])
        #expect(inventory.hostSettings.map(\.fileHasListener) == [true])
    }

    @Test("5.x: a transport given a host expression is configurable")
    func transportExpression() {
        let inventory = Self.inventory(
            "let transport = HTTPServerTransport(port: port, host: host, authentication: authentication)", Self.five)
        #expect(inventory.listeners.map(\.host) == [.expression("host", defaultValue: nil)])
        #expect(inventory.listeners.map(\.authentication) == [.notVisible])
    }

    // MARK: - 5.x: who it answers

    @Test("5.x: authentication: .unauthenticated on a transport is explicitly none")
    func transportUnauthenticated() {
        let inventory = Self.inventory(
            "let transport = HTTPServerTransport(port: 8080, authentication: .unauthenticated)", Self.five)
        #expect(inventory.listeners.map(\.authentication) == [.explicitlyNone(names: ["authentication"])])
        #expect(inventory.authSettings.map(\.kind) == [.argument])
        #expect(inventory.authSettings.map(\.names) == [["authentication"]])
        #expect(inventory.authSettings.map(\.value) == [".unauthenticated"])
        #expect(inventory.authSettings.map(\.callee) == ["HTTPServerTransport"])
        #expect(inventory.authenticationOffByDefault.count == 1)
    }

    @Test("5.x: the qualified spelling is the same case")
    func transportUnauthenticatedQualified() {
        let inventory = Self.inventory(
            "let transport = HTTPServerTransport(port: 8080, authentication: HTTPAuthentication.unauthenticated)", Self.five)
        #expect(inventory.listeners.map(\.authentication) == [.explicitlyNone(names: ["authentication"])])
    }

    @Test("5.x: an enforcing case on a transport is authenticated", arguments: [
        (".apiKey(authenticator)", "apiKey"),
        (".oauth(server)", "oauth"),
        (".apiKeyOrOAuth(authenticator, server)", "apiKeyOrOAuth"),
        ("HTTPAuthentication.apiKey(authenticator)", "apiKey"),
    ])
    func transportAuthenticated(argument: String, name: String) {
        let inventory = Self.inventory(
            "let transport = HTTPServerTransport(port: 8080, authentication: \(argument))", Self.five)
        #expect(inventory.listeners.map(\.authentication) == [.authenticated(by: [name])])
        #expect(inventory.authSettings.isEmpty)
        #expect(inventory.authenticationOffByDefault.isEmpty)
    }

    @Test("5.x: .authentication(.unauthenticated) on a builder is explicitly none, at the line it is written on")
    func builderUnauthenticated() {
        let inventory = Self.inventory("""
            try await MCPServer.builder()
                .serverName("x")
                .authentication(.unauthenticated)
                .run()
            """, Self.five)
        #expect(inventory.listeners.map(\.authentication) == [.explicitlyNone(names: ["authentication"])])
        #expect(inventory.authSettings.map(\.kind) == [.argument])
        #expect(inventory.authSettings.map(\.names) == [["authentication"]])
        #expect(inventory.authSettings.map(\.value) == [".unauthenticated"])
        #expect(inventory.authSettings.map(\.callee) == ["MCPServerBuilder"])
        #expect(inventory.authSettings.map(\.site.line) == [4])
    }

    @Test("A builder given an authenticator is authenticated", arguments: [
        (".authentication(.apiKey(authenticator))", "apiKey"),
        (".authentication(.oauth(server))", "oauth"),
        (".authenticator(authenticator)", "authenticator"),
        (".oauthServer(server)", "oauthServer"),
    ])
    func builderAuthenticated(call: String, name: String) {
        let inventory = Self.inventory("try await MCPServer.builder()\(call).run()", Self.five)
        #expect(inventory.listeners.map(\.authentication) == [.authenticated(by: [name])])
        #expect(inventory.authSettings.isEmpty)
    }

    @Test("A builder whose authentication is an expression decides nothing in source")
    func builderAuthenticationExpression() {
        let inventory = Self.inventory("try await MCPServer.builder().authentication(chosen).run()", Self.five)
        #expect(inventory.listeners.map(\.authentication) == [.notVisible])
        #expect(inventory.authSettings.isEmpty)
    }

    @Test("5.x: an enforcing .authentication on the builder stands in front of its tools")
    func builderAuthenticationReachesHandlers() {
        let inventory = Self.inventory("""
            struct Tool: MCPToolHandler { let tool = MCPTool(name: "t", description: "", inputSchema: s) }
            try await MCPServer.builder().authentication(.apiKey(authenticator)).tools([Tool()]).run()
            """, Self.five)
        #expect(inventory.handlers.map(\.auth.transport) == [["authentication"]])
        #expect(inventory.handlers.map(\.auth.verdict) == [.protected])
    }

    @Test("5.x: .authentication(.unauthenticated) on the builder puts nothing in front of its tools")
    func builderUnauthenticatedDoesNotProtectHandlers() {
        let inventory = Self.inventory("""
            struct Tool: MCPToolHandler { let tool = MCPTool(name: "t", description: "", inputSchema: s) }
            try await MCPServer.builder().authentication(.unauthenticated).tools([Tool()]).run()
            """, Self.five)
        #expect(inventory.handlers.map(\.auth.transport) == [[]])
        #expect(inventory.handlers.map(\.auth.verdict) == [.none])
    }

    // MARK: - 4.x

    @Test("4.x: a builder inherits the library's all-interfaces bind")
    func builderFour() {
        let inventory = Self.inventory("try await MCPServer.builder().serverName(\"x\").tools(t).run()", Self.four)
        #expect(inventory.listeners.map(\.host) == [
            .inherited(library: "SwiftMCPServer", kind: .allInterfaces, note: Self.builderNote4),
        ])
        #expect(inventory.boundToAllInterfaces.map(\.construct) == ["MCPServer.builder"])
        #expect(inventory.listeners.map(\.host.isHardCoded) == [true])
    }

    @Test("4.x: a transport inherits the library's all-interfaces bind")
    func transportFour() {
        let inventory = Self.inventory(
            "let transport = HTTPServerTransport(port: port, authenticator: authenticator)", Self.four)
        #expect(inventory.listeners.map(\.host) == [
            .inherited(library: "SwiftMCPServer", kind: .allInterfaces, note: Self.transportNote4),
        ])
        #expect(inventory.boundToAllInterfaces.map(\.construct) == ["HTTPServerTransport"])
    }

    @Test("4.x: authenticator: nil on a transport is still explicitly none")
    func transportFourNil() {
        let inventory = Self.inventory(
            "let transport = HTTPServerTransport(port: port, authenticator: nil, oauthServer: nil)", Self.four)
        #expect(inventory.listeners.map(\.authentication) == [.explicitlyNone(names: ["authenticator", "oauthServer"])])
    }

    // MARK: - Which release

    /// `(manifest requirement, resolved version, expected major, evidence, detail)`.
    static let releases: [(name: String, requirement: String?, resolved: String?, major: Int,
                           evidence: LibraryRelease.Evidence, detail: String)] = [
        ("from: 4", url + ", from: \"4.4.1\"", nil, 4, .manifest, "from: \"4.4.1\" in Package.swift"),
        ("from: 5", url + ", from: \"5.0.0\"", nil, 5, .manifest, "from: \"5.0.0\" in Package.swift"),
        ("exact", url + ", exact: \"4.5.0\"", nil, 4, .manifest, "exact: \"4.5.0\" in Package.swift"),
        ("upToNextMajor", url + ", .upToNextMajor(from: \"4.0.0\")", nil, 4, .manifest,
         ".upToNextMajor(from: \"4.0.0\") in Package.swift"),
        ("no .git, a different case", "url: \"https://github.com/jpurnell/swiftmcpserver\", from: \"5.1.0\"", nil, 5,
         .manifest, "from: \"5.1.0\" in Package.swift"),
        ("a range within one major", url + ", \"4.2.0\"..<\"5.0.0\"", nil, 4, .manifest,
         "\"4.2.0\"..<\"5.0.0\" in Package.swift"),
        ("a range across majors, pinned", url + ", \"4.2.0\"..<\"6.0.0\"", "5.0.0", 5, .resolved,
         "5.0.0 in Package.resolved"),
        ("a branch, pinned to a version", url + ", branch: \"main\"", "4.5.0", 4, .resolved,
         "4.5.0 in Package.resolved"),
        ("the manifest agrees with the pin", url + ", from: \"4.4.1\"", "4.4.3", 4, .manifest,
         "from: \"4.4.1\" in Package.swift, 4.4.3 in Package.resolved"),
        ("the manifest excludes a stale pin", url + ", from: \"5.0.0\"", "1.0.0", 5, .manifest,
         "from: \"5.0.0\" in Package.swift; Package.resolved still pins 1.0.0"),
        ("transitive: only a pin", nil, "4.4.1", 4, .resolved, "4.4.1 in Package.resolved"),
        ("an old major is read with the 4.x facts", nil, "1.0.0", 1, .resolved, "1.0.0 in Package.resolved"),
    ]

    @Test("The release is read from the manifest requirement, then the pin", arguments: releases.map(\.name))
    func declaredRelease(name: String) throws {
        let fixture = try #require(Self.releases.first { $0.name == name })
        let dependencies = PackageDependencies(
            manifest: fixture.requirement.map(Self.manifest), resolved: fixture.resolved.map(Self.resolved))
        #expect(dependencies.release(of: "SwiftMCPServer") == LibraryRelease(
            library: "SwiftMCPServer", major: fixture.major, evidence: fixture.evidence, detail: fixture.detail))
        #expect(dependencies.release(of: "SwiftMCPServer")?.bindsLoopbackByDefault == (fixture.major >= 5))
    }

    @Test("Neither file decides", arguments: [
        url + ", branch: \"main\"",
        url + ", revision: \"1270bd2\"",
        "path: \"../SwiftMCPServer\"",
        url + ", \"4.2.0\"..<\"6.0.0\"",
    ])
    func undeclaredRelease(requirement: String) {
        #expect(PackageDependencies(manifest: Self.manifest(requirement)).release(of: "SwiftMCPServer") == nil)
    }

    @Test("A package that does not name the library declares nothing about it")
    func absentLibrary() {
        let dependencies = PackageDependencies(
            manifest: Self.manifest("url: \"https://github.com/vapor/vapor.git\", from: \"4.0.0\""),
            resolved: "{ \"pins\" : [], \"version\" : 3 }")
        #expect(dependencies.release(of: "SwiftMCPServer") == nil)
        #expect(PackageDependencies.unknown.release(of: "SwiftMCPServer") == nil)
        #expect(PackageDependencies(resolved: "not json").release(of: "SwiftMCPServer") == nil)
    }

    @Test("A version 1 Package.resolved is read too")
    func resolvedVersionOne() {
        let dependencies = PackageDependencies(resolved: """
            { "object": { "pins": [ { "package": "SwiftMCPServer",
              "repositoryURL": "https://github.com/jpurnell/SwiftMCPServer.git",
              "state": { "branch": null, "revision": "abc", "version": "4.1.0" } } ] }, "version": 1 }
            """)
        #expect(dependencies.release(of: "SwiftMCPServer") == LibraryRelease(
            library: "SwiftMCPServer", major: 4, evidence: .resolved, detail: "4.1.0 in Package.resolved"))
    }

    @Test("The inventory records the release its SwiftMCPServer rows were read with")
    func inventoryRecordsRelease() {
        let four = Self.inventory("try await MCPServer.builder().run()", Self.four)
        #expect(four.libraries == [LibraryRelease(
            library: "SwiftMCPServer", major: 4, evidence: .manifest, detail: "from: \"4.4.1\" in Package.swift")])
        let none = ServerSurfaceInventory.build(
            sources: [("Sources/Lib/A.swift", "let x = 1")], dependencies: Self.four)
        #expect(none.libraries.isEmpty)
    }

    // MARK: - When nothing declares it

    @Test("Undeclared: authenticator: or oauthServer: on a transport is the 4.x initialiser, so the 4.x facts apply")
    func shapeFour() {
        let inventory = Self.inventory("let transport = HTTPServerTransport(port: port, authenticator: authenticator)")
        #expect(inventory.libraries == [LibraryRelease(
            library: "SwiftMCPServer", major: 4, evidence: .apiShape,
            detail: "HTTPServerTransport is given authenticator: or oauthServer:, which 5.0.0 removed")])
        #expect(inventory.listeners.map(\.host) == [
            .inherited(library: "SwiftMCPServer", kind: .allInterfaces, note: Self.transportNote4),
        ])
    }

    @Test("Undeclared: a 5.0.0 spelling anywhere is the 5.x library", arguments: [
        "let transport = HTTPServerTransport(port: port, authentication: authentication)",
        "try await MCPServer.builder().listen(host: host).run()",
        "try await MCPServer.builder().authentication(chosen).run()",
    ])
    func shapeFive(source: String) {
        let inventory = Self.inventory(source)
        #expect(inventory.libraries == [LibraryRelease(
            library: "SwiftMCPServer", major: 5, evidence: .apiShape,
            detail: "the source uses host:, listen(host:) or authentication, which 5.0.0 added")])
    }

    @Test("Undeclared and shapeless: the 5.x facts are assumed, and the inventory says it assumed")
    func assumed() {
        let inventory = Self.inventory("try await MCPServer.builder().serverName(\"x\").tools(t).run()")
        #expect(inventory.libraries == [LibraryRelease(
            library: "SwiftMCPServer", major: 5, evidence: .assumed,
            detail: "no requirement, pin or version-specific call found; 5.x assumed")])
        #expect(inventory.listeners.map(\.host) == [.frameworkDefault(.loopback, note: Self.builderNote5)])
    }

    @Test("A declared release outranks the shape of the calls")
    func declaredOutranksShape() {
        let inventory = Self.inventory(
            "let transport = HTTPServerTransport(port: port, authenticator: authenticator)", Self.five)
        #expect(inventory.libraries.map(\.major) == [5])
        #expect(inventory.libraries.map(\.evidence) == [.manifest])
    }

    // MARK: - Summary

    @Test("The summary names the release and what it means for the bind")
    func summary() {
        let four = Self.inventory("try await MCPServer.builder().run()", Self.four)
        #expect(four.summary == "examined 1 file · 1 listener (swift-mcp-server 1) · 1 bound to all interfaces · "
            + "0 with authentication off by default · 0 handlers · SwiftMCPServer read as 4.x "
            + "(from: \"4.4.1\" in Package.swift): binds 0.0.0.0 and takes no host")
        let five = Self.inventory("try await MCPServer.builder().run()", Self.five)
        #expect(five.summary == "examined 1 file · 1 listener (swift-mcp-server 1) · 0 bound to all interfaces · "
            + "0 with authentication off by default · 0 handlers · SwiftMCPServer read as 5.x "
            + "(from: \"5.0.0\" in Package.swift): binds 127.0.0.1 unless source says otherwise; "
            + "--host at launch is not visible")
    }

    @Test("The inventory with a release round-trips through JSON")
    func jsonRoundTrip() throws {
        let inventory = Self.inventory(
            "let transport = HTTPServerTransport(port: 8080, authentication: .apiKey(authenticator))", Self.five)
        let decoded = try JSONDecoder().decode(ServerSurfaceInventory.self, from: JSONEncoder().encode(inventory))
        #expect(decoded == inventory)
    }
}
