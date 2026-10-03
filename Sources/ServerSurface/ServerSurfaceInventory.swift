import Foundation

/// What one package exposes to a network, read from its source.
///
/// A **listener** is a place the package opens a socket — where it binds and whether the address
/// can be narrowed. A **handler** is a place a request from that socket starts running the
/// package's code — a Vapor route, an MCP tool, a `case` in a hand-written dispatcher — with the
/// authentication facts that are visible beside it. The inventory decides nothing: it is the
/// table rules read. `security.bind-all-interfaces` and `security.listener-auth-optional` are
/// its first consumers; body ceilings, credential kind, response headers and error detail are
/// columns later rules add (see ``ServerSurfaceColumn``).
///
/// Built in two steps so a checker that already walks every file pays for one more visitor and
/// no second parse: ``ServerSurfaceFileFacts/collect(from:converter:fileName:)`` per file, then
/// ``init(files:targets:guardTypes:)`` once per package, which joins what one file cannot see
/// alone — a host default declared in an initialiser and bound in another method, a
/// `RouteCollection` registered in one file and declared in another, an authenticator parameter
/// in the same target as a socket.
///
/// ## What it does not see
///
/// Stated here because a table that omits a row looks exactly like a table with nothing to
/// omit. See <doc:ServerSurface> for the full list.
///
/// - A route group composed across function boundaries: a `RoutesBuilder` passed into a helper
///   function that is not `boot(routes:)` arrives with an unknown lineage.
/// - Registration at runtime — handlers built from a list, `buildToolHandlers()`, paths that are
///   not literals (recorded as `<dynamic>`).
/// - Dispatch written as a chain of `if request.path == …`.
/// - The deployed configuration: a `--hostname` flag, a reverse proxy, a launchd environment.
public struct ServerSurfaceInventory: Sendable, Codable, Equatable {

    /// Every socket the package opens, in source order.
    public var listeners: [ServerListener]

    /// Every handler a network caller can reach, in source order.
    public var handlers: [ServerHandler]

    /// Host addresses chosen in source — bind arguments, defaults, assignments.
    public var hostSettings: [HostSetting]

    /// Authentication switches visible in source — optional authenticators, environment flags,
    /// authenticators passed as `nil`.
    public var authSettings: [AuthSetting]

    /// Files the inventory was built from.
    public var examinedFiles: Int

    /// Types that open a listener in this package — `TournamentWebSocketServer`, `SSHServer`.
    ///
    /// Constructing one of these is starting a listener, which is how a `host:` argument at a
    /// call site in another file is recognised as a bind address.
    public var listenerOwningTypes: Set<String>

    /// Targets containing at least one listener outside a test target.
    public var listenerTargets: Set<String>

    /// Creates an inventory from already-assembled parts. Most callers want
    /// ``init(files:targets:guardTypes:)``.
    public init(
        listeners: [ServerListener] = [],
        handlers: [ServerHandler] = [],
        hostSettings: [HostSetting] = [],
        authSettings: [AuthSetting] = [],
        examinedFiles: Int = 0,
        listenerOwningTypes: Set<String> = [],
        listenerTargets: Set<String> = []
    ) {
        self.listeners = listeners
        self.handlers = handlers
        self.hostSettings = hostSettings
        self.authSettings = authSettings
        self.examinedFiles = examinedFiles
        self.listenerOwningTypes = listenerOwningTypes
        self.listenerTargets = listenerTargets
    }

    /// Listeners outside test targets — the ones a deployment can expose.
    public var productionListeners: [ServerListener] { listeners.filter { !$0.inTestTarget } }

    /// Handlers outside test targets.
    public var productionHandlers: [ServerHandler] { handlers.filter { !$0.inTestTarget } }

    /// Whether `target` opens a socket. A `nil` target — a file no target claims, or a single
    /// source audited alone — is the package's anonymous target.
    public func targetHasListener(_ target: String?) -> Bool {
        listenerTargets.contains(target ?? Self.anonymousTarget)
    }

    /// The key used for files no target claims.
    public static let anonymousTarget = "<package>"
}

// MARK: - Sites

/// Where something is, in the form every report in the gate uses.
public struct SourceSite: Sendable, Codable, Hashable, Comparable {
    /// The file, as the caller named it.
    public let file: String
    /// 1-based line.
    public let line: Int
    /// 1-based column.
    public let column: Int

    /// Creates a site.
    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    /// Orders by file, then line, then column — source order, stable under file reordering.
    public static func < (lhs: SourceSite, rhs: SourceSite) -> Bool {
        (lhs.file, lhs.line, lhs.column) < (rhs.file, rhs.line, rhs.column)
    }
}

// MARK: - Frameworks and addresses

/// Which recogniser produced a row. Nothing downstream should need it to decide a verdict; it
/// is printed so a reader knows which rules of evidence applied.
public enum ServerFramework: String, Sendable, Codable, CaseIterable, Comparable {
    /// Vapor 4 — `Application`, `RoutesBuilder`, route groups.
    case vapor
    /// jpurnell/SwiftMCPServer — `MCPServer.builder()`, `MCPToolHandler`, `HTTPServerTransport`.
    case swiftMCPServer = "swift-mcp-server"
    /// The MCP Swift SDK used directly — `Server.withMethodHandler(_:handler:)`.
    case mcpSDK = "mcp-sdk"
    /// SwiftNIO by hand — `ServerBootstrap`, `channelRead`, `switch (method, path)`.
    case nio
    /// Network.framework — `NWListener`.
    case network

    /// Declaration order, for stable printing.
    public static func < (lhs: ServerFramework, rhs: ServerFramework) -> Bool {
        let order = Self.allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

/// What an address literal means for who can connect.
public enum HostAddressKind: String, Sendable, Codable, Hashable {
    /// `0.0.0.0`, `::`, `[::]` — every interface the machine has. CWE-1327.
    case allInterfaces = "all-interfaces"
    /// `127.0.0.1`, `::1`, `localhost` — this machine only.
    case loopback
    /// Any other literal: one named interface.
    case specific

    /// Classifies a host literal.
    ///
    /// An empty string is all interfaces only where it is handed to a bind: there, as in
    /// `getaddrinfo`, no host means any. As a default for a `host` property it more often means
    /// "unset", so ``HostSetting`` does not call this for empty defaults.
    public static func classify(_ literal: String) -> HostAddressKind {
        let value = literal.trimmingCharacters(in: .whitespaces).lowercased()
        if allInterfaceLiterals.contains(value) { return .allInterfaces }
        if loopbackLiterals.contains(value) || value.hasPrefix("127.") { return .loopback }
        return .specific
    }

    /// Literals that mean every interface.
    public static let allInterfaceLiterals: Set<String> = ["0.0.0.0", "::", "[::]", ""]

    /// Literals that mean this machine only.
    public static let loopbackLiterals: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]
}

/// Where a listener binds, as far as source says.
public enum HostBinding: Sendable, Codable, Hashable {
    /// A string literal at the bind: `bind(host: "0.0.0.0", …)`.
    case literal(String, HostAddressKind)
    /// An expression at the bind — the caller or the operator decides. `defaultValue` is the
    /// literal default of the parameter or property the expression names, when the owning type
    /// declares one: `SSHServer.init(host: String = "0.0.0.0")` then `bind(host: host)`.
    case expression(String, defaultValue: HostDefault?)
    /// No address in source; the framework's own default applies. Vapor binds `127.0.0.1`;
    /// an `NWListener` with no `requiredLocalEndpoint` accepts on every interface.
    case frameworkDefault(HostAddressKind, note: String)
    /// A listener started inside a dependency, whose address this package cannot set.
    case inherited(library: String, kind: HostAddressKind?, note: String)
    /// A Unix-domain socket — no host to be `0.0.0.0`.
    case unixSocket
    /// Configured somewhere the recogniser does not follow.
    case unknown

    /// The address kind, when source decides it.
    public var kind: HostAddressKind? {
        switch self {
        case .literal(_, let kind): return kind
        case .expression(_, let fallback): return fallback?.kind
        case .frameworkDefault(let kind, _): return kind
        case .inherited(_, let kind, _): return kind
        case .unixSocket, .unknown: return nil
        }
    }

    /// Whether the address is fixed in source, so a caller cannot narrow it.
    public var isHardCoded: Bool {
        switch self {
        case .literal, .inherited: return true
        case .expression, .frameworkDefault, .unixSocket, .unknown: return false
        }
    }
}

/// The literal default of the declaration a bind expression names.
public struct HostDefault: Sendable, Codable, Hashable {
    /// The literal, without quotes.
    public let value: String
    /// What it means.
    public let kind: HostAddressKind
    /// Where the default is written.
    public let site: SourceSite

    /// Creates a default.
    public init(value: String, kind: HostAddressKind, site: SourceSite) {
        self.value = value
        self.kind = kind
        self.site = site
    }
}

// MARK: - Listeners

/// One place the package opens a socket.
public struct ServerListener: Sendable, Codable, Hashable {
    /// Where the socket is opened — the bind call, the `NWListener(`, the `Application.make(`.
    public var site: SourceSite
    /// The owning SwiftPM target, when the manifest says.
    public var target: String?
    /// Whether that target is a test target. Test listeners are recorded and not counted.
    public var inTestTarget: Bool
    /// Which recogniser found it.
    public var framework: ServerFramework
    /// The construct, as printed: `ServerBootstrap.bind`, `NWListener`, `Application.make`,
    /// `MCPServer.builder`, `HTTPServerTransport`, `SSHServer`.
    public var construct: String
    /// Where it binds.
    public var host: HostBinding
    /// The port expression, as written, when there is one.
    public var port: String?
    /// The type whose code opens the socket.
    public var owningType: String?
    /// How authentication is decided for this listener's target, from ``AuthSetting``s.
    public var authentication: ListenerAuthentication
    /// Columns later rules add. Empty until they do.
    public var columns: [ServerSurfaceColumn: ColumnValue]

    /// Creates a listener row.
    public init(
        site: SourceSite,
        target: String? = nil,
        inTestTarget: Bool = false,
        framework: ServerFramework,
        construct: String,
        host: HostBinding,
        port: String? = nil,
        owningType: String? = nil,
        authentication: ListenerAuthentication = .notVisible,
        columns: [ServerSurfaceColumn: ColumnValue] = [:]
    ) {
        self.site = site
        self.target = target
        self.inTestTarget = inTestTarget
        self.framework = framework
        self.construct = construct
        self.host = host
        self.port = port
        self.owningType = owningType
        self.authentication = authentication
        self.columns = columns
    }
}

/// What source says about authentication in front of a listener.
public enum ListenerAuthentication: Sendable, Codable, Hashable {
    /// An authenticator parameter or property in the target defaults to off: whoever constructs
    /// the listener without one gets a server that authenticates nobody.
    case optionalByDefault(names: [String])
    /// An environment variable can switch authentication off at launch.
    case environmentSwitch(keys: [String])
    /// The listener is constructed with its authenticator passed as `nil` / `.none`.
    case explicitlyNone(names: [String])
    /// Nothing in source decides it either way.
    case notVisible
}

// MARK: - Handlers

/// What sort of handler a row is.
public enum HandlerKind: String, Sendable, Codable, CaseIterable, Comparable {
    /// A Vapor route: `app.post("x") { … }`, `routes.get(use: index)`.
    case route
    /// An `MCPToolHandler` conformer, or a tool registered with the SDK.
    case mcpTool = "mcp-tool"
    /// An `MCPResourceProvider` / `MCPPromptProvider` conformer.
    case mcpProvider = "mcp-provider"
    /// An `MCPHTTPRoute(…)` — a plain HTTP route on an MCP server.
    case mcpHTTPRoute = "mcp-http-route"
    /// `Server.withMethodHandler(T.self) { … }` on the MCP SDK.
    case mcpMethodHandler = "mcp-method-handler"
    /// One `case (.METHOD, "path"):` of a hand-written `switch` in an NIO handler.
    case dispatchCase = "dispatch-case"
    /// A `channelRead` on a handler installed by a server bootstrap.
    case channelHandler = "channel-handler"
    /// A WebSocket upgrade — `NIOWebSocketServerUpgrader(…)`.
    case webSocketUpgrade = "websocket-upgrade"

    /// Declaration order, for stable printing.
    public static func < (lhs: HandlerKind, rhs: HandlerKind) -> Bool {
        let order = Self.allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

/// One handler a network caller can reach.
public struct ServerHandler: Sendable, Codable, Hashable {
    /// The registration — the route call, the conformance, the `case`.
    public var site: SourceSite
    /// The owning SwiftPM target.
    public var target: String?
    /// Whether that target is a test target.
    public var inTestTarget: Bool
    /// Which recogniser found it.
    public var framework: ServerFramework
    /// What sort of handler.
    public var kind: HandlerKind
    /// `GET`, `POST`, …; `tools/call` for an MCP tool; `nil` where there is no method.
    public var method: String?
    /// The path or name, with any group prefix: `/v1/runway`, `ledger_runway`, `<dynamic>`.
    public var route: String
    /// What stands in front of it.
    public var auth: HandlerAuth
    /// Columns later rules add.
    public var columns: [ServerSurfaceColumn: ColumnValue]

    /// Creates a handler row.
    public init(
        site: SourceSite,
        target: String? = nil,
        inTestTarget: Bool = false,
        framework: ServerFramework,
        kind: HandlerKind,
        method: String?,
        route: String,
        auth: HandlerAuth = HandlerAuth(),
        columns: [ServerSurfaceColumn: ColumnValue] = [:]
    ) {
        self.site = site
        self.target = target
        self.inTestTarget = inTestTarget
        self.framework = framework
        self.kind = kind
        self.method = method
        self.route = route
        self.auth = auth
        self.columns = columns
    }

    /// The route path for a dynamic, non-literal component.
    public static let dynamicRoute = "<dynamic>"
}

/// Authentication facts visible at a handler. Facts, not a verdict: ``verdict`` is one reading
/// of them, and a rule is free to read them differently.
public struct HandlerAuth: Sendable, Codable, Hashable {
    /// Guards in the lineage — `User.guardMiddleware()`, `redirectMiddleware(…)`, or a type the
    /// caller named in `guardTypes`.
    public var guards: [String]
    /// Authenticators in the lineage. An authenticator does not reject: Vapor says so.
    public var authenticators: [String]
    /// Other middleware in the lineage, unclassified — `RequireAuthMiddleware()` is here until
    /// someone names it a guard.
    public var middleware: [String]
    /// `app.middleware.use(…)` in the handler's target, which wraps every route.
    public var applicationMiddleware: [String]
    /// The handler body calls `req.auth.require(…)`.
    public var requiresInHandler: Bool
    /// Authentication attached at the transport — `.authenticator(…)`, `.oauthServer(…)` on an
    /// MCP builder chain in the package.
    public var transport: [String]
    /// `requiresAuthentication:` as written on an `MCPHTTPRoute`, when it is a literal.
    public var declaredRequiresAuthentication: Bool?
    /// Whether the route group lineage was resolved. `false` for a `RouteCollection` the scan
    /// never saw registered: *unknown*, which is not *empty*.
    public var lineageKnown: Bool
    /// Sites a `RouteCollection` was registered at, when more than one — the row carries the
    /// weakest lineage and this says where the others were.
    public var otherRegistrations: [SourceSite]

    /// Creates an auth record.
    public init(
        guards: [String] = [],
        authenticators: [String] = [],
        middleware: [String] = [],
        applicationMiddleware: [String] = [],
        requiresInHandler: Bool = false,
        transport: [String] = [],
        declaredRequiresAuthentication: Bool? = nil,
        lineageKnown: Bool = true,
        otherRegistrations: [SourceSite] = []
    ) {
        self.guards = guards
        self.authenticators = authenticators
        self.middleware = middleware
        self.applicationMiddleware = applicationMiddleware
        self.requiresInHandler = requiresInHandler
        self.transport = transport
        self.declaredRequiresAuthentication = declaredRequiresAuthentication
        self.lineageKnown = lineageKnown
        self.otherRegistrations = otherRegistrations
    }

    /// One reading of the facts, following `AHandlerSaysWhoMayCallIt.md` §3.2.
    public var verdict: HandlerAuthVerdict {
        if declaredRequiresAuthentication == false { return .declaredPublic }
        if !guards.isEmpty || requiresInHandler || !transport.isEmpty
            || declaredRequiresAuthentication == true {
            return .protected
        }
        if !lineageKnown { return .unknown }
        if !authenticators.isEmpty { return .authenticatorOnly }
        if !middleware.isEmpty || !applicationMiddleware.isEmpty { return .unclassifiedMiddleware }
        return .none
    }
}

/// ``HandlerAuth/verdict``'s answers.
public enum HandlerAuthVerdict: String, Sendable, Codable, CaseIterable {
    /// A guard, a `require`, or transport authentication stands in front.
    case protected
    /// Declared public in code (`requiresAuthentication: false`).
    case declaredPublic = "declared-public"
    /// Only an authenticator — which admits a failed authentication.
    case authenticatorOnly = "authenticator-only"
    /// Middleware the inventory cannot classify.
    case unclassifiedMiddleware = "unclassified-middleware"
    /// The lineage was not resolved.
    case unknown
    /// Nothing.
    case none
}

// MARK: - Settings

/// A host address chosen in source, wherever it was written.
public struct HostSetting: Sendable, Codable, Hashable {
    /// How the address was written.
    public enum Kind: String, Sendable, Codable, Hashable {
        /// The `host:` argument of a `bind` (or `.hostPort(host:…)` endpoint).
        case bindArgument = "bind-argument"
        /// A function or initialiser parameter's default.
        case parameterDefault = "parameter-default"
        /// A stored property's (or local binding's) initial value, `@Option` included.
        case propertyDefault = "property-default"
        /// An assignment to a member named `hostname` or `host`.
        case assignment
        /// A `host:` / `hostname:` / `bindAddress:` argument to some other call.
        case argument
    }

    /// Where the literal is.
    public var site: SourceSite
    /// The owning target.
    public var target: String?
    /// Whether that target is a test target.
    public var inTestTarget: Bool
    /// How it was written.
    public var kind: Kind
    /// The parameter, property, member or argument label.
    public var name: String
    /// The literal.
    public var value: String
    /// What it means.
    public var addressKind: HostAddressKind
    /// For ``Kind/argument``: the callee's last name component — `TournamentWebSocketServer`.
    public var callee: String?
    /// For ``Kind/argument``: whether the file also constructs a listener.
    public var fileHasListener: Bool
    /// The type the declaration sits in.
    public var owningType: String?

    /// Creates a host setting.
    public init(
        site: SourceSite,
        target: String? = nil,
        inTestTarget: Bool = false,
        kind: Kind,
        name: String,
        value: String,
        addressKind: HostAddressKind,
        callee: String? = nil,
        fileHasListener: Bool = false,
        owningType: String? = nil
    ) {
        self.site = site
        self.target = target
        self.inTestTarget = inTestTarget
        self.kind = kind
        self.name = name
        self.value = value
        self.addressKind = addressKind
        self.callee = callee
        self.fileHasListener = fileHasListener
        self.owningType = owningType
    }
}

/// An authentication switch visible in source.
public struct AuthSetting: Sendable, Codable, Hashable {
    /// How the switch was written.
    public enum Kind: String, Sendable, Codable, Hashable {
        /// A parameter defaulting to off: `authenticator: APIKeyAuthenticator? = nil`.
        case parameterDefault = "parameter-default"
        /// A stored property initialised to off.
        case propertyDefault = "property-default"
        /// A flag read from the process environment.
        case environmentFlag = "environment-flag"
        /// An authenticator argument passed as `nil` / `.none` when constructing a listener.
        case argument
    }

    /// What the switch does when nobody touches it.
    public enum State: String, Sendable, Codable, Hashable {
        /// Off: no authentication unless someone adds it.
        case off
        /// Off unless an environment variable is set.
        case offUnlessSet = "off-unless-set"
        /// On unless an environment variable turns it off.
        case onUnlessDisabled = "on-unless-disabled"
    }

    /// Where it is.
    public var site: SourceSite
    /// The owning target.
    public var target: String?
    /// Whether that target is a test target.
    public var inTestTarget: Bool
    /// How it was written.
    public var kind: Kind
    /// The parameter, property, binding or argument names (an argument site may name two).
    public var names: [String]
    /// The default or argument, as written.
    public var value: String
    /// What it does when nobody touches it.
    public var state: State
    /// For ``Kind/environmentFlag``: the variable's name, when it is a literal.
    public var environmentKey: String?
    /// For ``Kind/argument``: the callee's last name component.
    public var callee: String?

    /// Creates an auth setting.
    public init(
        site: SourceSite,
        target: String? = nil,
        inTestTarget: Bool = false,
        kind: Kind,
        names: [String],
        value: String,
        state: State,
        environmentKey: String? = nil,
        callee: String? = nil
    ) {
        self.site = site
        self.target = target
        self.inTestTarget = inTestTarget
        self.kind = kind
        self.names = names
        self.value = value
        self.state = state
        self.environmentKey = environmentKey
        self.callee = callee
    }
}

// MARK: - Columns

/// A column a later rule adds to listener or handler rows.
///
/// Named here so the proposals that need them agree on one spelling, and so adding one is a
/// new static constant rather than a change to every row's shape. Values are text plus the site
/// that decided them; a rule that needs structure parses its own column.
public struct ServerSurfaceColumn: RawRepresentable, Sendable, Codable, Hashable, Comparable {
    /// The column's name, as printed.
    public let rawValue: String

    /// Creates a column key.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Orders columns by name.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Body ceiling — a byte count and where it was set, `default (16 KB)`, or `none`.
    /// `BytesFromOutsideNeedACeiling.md` §3.1.
    public static let bodyCeiling = ServerSurfaceColumn(rawValue: "body-ceiling")
    /// The limiter in front of the handler, or `none`. `BytesFromOutsideNeedACeiling.md` §3.1.
    public static let admission = ServerSurfaceColumn(rawValue: "admission")
    /// What kind of credential reaches the handler — ambient, header, none, unknown.
    /// `TheBrowserSendsTheCookieForYou.md` §3.1.
    public static let credential = ServerSurfaceColumn(rawValue: "credential")
    /// Cross-origin policy in front of the handler. `TheBrowserSendsTheCookieForYou.md` §3.4.
    public static let cors = ServerSurfaceColumn(rawValue: "cors")
    /// Whether the pipeline validates response headers. `AStringThatEndsALineStartsAnother.md`.
    public static let responseHeaders = ServerSurfaceColumn(rawValue: "response-headers")
    /// What an error thrown from the handler sends back. `AnErrorIsNotAResponse.md`.
    public static let errorDetail = ServerSurfaceColumn(rawValue: "error-detail")
}

/// One cell of a ``ServerSurfaceColumn``.
public struct ColumnValue: Sendable, Codable, Hashable {
    /// The cell, as printed.
    public var text: String
    /// Where the value was decided, when somewhere in source decided it.
    public var site: SourceSite?

    /// Creates a cell.
    public init(_ text: String, site: SourceSite? = nil) {
        self.text = text
        self.site = site
    }
}
