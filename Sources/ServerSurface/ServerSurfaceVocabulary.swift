import Foundation

/// The names the recognisers match, in one place so a reviewer can disagree with them.
///
/// Every list is exact-match on purpose. A looser pattern (`*auth*`) run over the portfolio
/// matched 13 parameters, 9 of them `author`, `authorSort`, `authority` and `authorURL`
/// (`AHandlerThatAnyoneCanCall.md` §3.1).
enum ServerSurfaceVocabulary {

    /// Names a host address is declared under.
    static let hostNames: Set<String> = [
        "host", "hostname", "bindAddress", "bindHost", "address", "listenAddress", "interface",
    ]

    /// Argument labels that pass a host to some other call. `address` and `interface` are left
    /// out here: as labels they name far more than bind addresses.
    static let hostArgumentLabels: Set<String> = [
        "host", "hostname", "bindAddress", "bindHost", "listenAddress",
    ]

    /// Callees whose `host:` argument is a destination, not a bind address.
    static let clientCallees: Set<String> = ["connect", "NWConnection", "URLComponents", "hostPort", "bind"]

    /// Names an authenticator or authoriser is passed under; off when one of
    /// ``offAuthenticators``.
    ///
    /// `apiKey`, `apiKeys` and `credentials` from the proposal's list are not here: their
    /// "empty" default is `[]`, and SwiftMCPServer's `APIKeyAuthenticator(apiKeys: [])` with
    /// `authRequired: true` rejects every request — an empty credential list is closed, not off.
    static let authenticatorNames: Set<String> = [
        "auth", "authenticator", "authentication", "authorizer", "oauthServer", "tokenValidator",
    ]

    /// Values that mean no authenticator: `nil`, `.none`, and SwiftMCPServer 5's
    /// `HTTPAuthentication.unauthenticated` — which has no case called `none` precisely so that
    /// running open is something a person spelled out.
    static let offAuthenticators: Set<String> = [
        "nil", ".none", ".unauthenticated", "HTTPAuthentication.unauthenticated",
    ]

    /// The cases of SwiftMCPServer 5's `HTTPAuthentication` that enforce something.
    static let enforcingAuthenticationCases: Set<String> = ["apiKey", "oauth", "apiKeyOrOAuth"]

    /// Names an authentication mode is passed under; off when one of ``offModes``.
    static let modeNames: Set<String> = ["authMode", "authenticationMode"]

    /// Mode cases that mean no authentication.
    static let offModes: Set<String> = [".none", ".disabled", ".off", ".open", ".anonymous", "nil"]

    /// Flags where `true` means authentication is on.
    static let onFlagNames: Set<String> = [
        "authRequired", "requireAuth", "requiresAuth", "requireAuthentication",
        "requiresAuthentication", "authenticationRequired", "authEnabled", "enableAuth",
        "authenticationEnabled",
    ]

    /// Flags where `true` means authentication is off.
    static let offFlagNames: Set<String> = [
        "authDisabled", "disableAuth", "noAuth", "skipAuth", "authenticationDisabled",
        "allowAnonymous",
    ]

    /// Library types that open a listener when constructed, and the library that owns each.
    ///
    /// The portfolio's two first-party server libraries. Inside the package that declares the
    /// type, its own `bind` is the listener and construction sites are not counted twice.
    static let knownListenerTypes: [String: String] = [
        "HTTPServerTransport": "SwiftMCPServer",
        "SSHServer": "SwiftCLIKit",
    ]

    /// What each known listener type does with its address when the caller says nothing, for
    /// the types whose answer does not depend on the release. `HTTPServerTransport`'s does: see
    /// ``transportNote(loopbackByDefault:)``.
    static let knownListenerNotes: [String: String] = [
        "SSHServer": "SSHServer binds 0.0.0.0 unless host: is passed",
    ]

    /// The library whose facts changed at a major version, as its package is named.
    static let swiftMCPServer = "SwiftMCPServer"

    /// The construct a `MCPServer.builder()` listener is recorded under.
    static let mcpBuilderConstruct = "MCPServer.builder"

    /// The construct a directly constructed transport is recorded under.
    static let mcpTransportConstruct = "HTTPServerTransport"

    /// The callee an authentication choice made on a builder chain is recorded under: the type
    /// `MCPServer.builder()` returns.
    static let mcpBuilderType = "MCPServerBuilder"

    /// Types whose authenticator arguments decide a listener's authentication, beyond the
    /// package's own listener-owning types.
    static let knownAuthCarriers: Set<String> = [
        "HTTPServerTransport", "SSHServer", "SSHConfiguration", mcpBuilderType,
    ]

    /// Labels only SwiftMCPServer 4.x's `HTTPServerTransport.init` takes; 5.0.0 replaced both
    /// with the required `authentication:`.
    static let transportLabelsRemovedInFive: Set<String> = ["authenticator", "oauthServer"]

    /// Labels only SwiftMCPServer 5's `HTTPServerTransport.init` takes.
    static let transportLabelsAddedInFive: Set<String> = ["authentication", "host", "allowedHosts"]

    /// Parameter types that make a binding routes-shaped in Vapor.
    static let routesTypes: Set<String> = [
        "Application", "Vapor.Application", "RoutesBuilder", "any RoutesBuilder",
        "some RoutesBuilder", "Vapor.RoutesBuilder",
    ]

    /// Vapor route registration methods.
    static let routeMethods: Set<String> = ["get", "post", "put", "patch", "delete", "on", "webSocket"]

    /// The note on a Vapor listener nobody assigned a hostname to.
    static let vaporDefaultNote =
        "Vapor binds 127.0.0.1 unless --hostname or configuration.hostname says otherwise"

    /// The note on an `NWListener` with no local endpoint.
    static let nwListenerDefaultNote = "NWListener with no requiredLocalEndpoint accepts on every interface"

    /// The note on a `MCPServer.builder()` chain that names no host.
    ///
    /// 5.0.0 made the address a setting — `listen(host:)` in source, `--host` at launch — with
    /// loopback as its default. Before it, the transport wrote `0.0.0.0` into the bind and the
    /// builder had nothing to say about it.
    static func builderNote(loopbackByDefault: Bool) -> String {
        loopbackByDefault
            ? "SwiftMCPServer 5 binds 127.0.0.1 unless listen(host:) or --host at launch says otherwise"
            : "SwiftMCPServer before 5.0.0 binds 0.0.0.0 and the builder cannot set the address"
    }

    /// The note on an `HTTPServerTransport(…)` given no `host:`.
    static func transportNote(loopbackByDefault: Bool) -> String {
        loopbackByDefault
            ? "HTTPServerTransport binds 127.0.0.1 unless host: is passed"
            : "HTTPServerTransport before SwiftMCPServer 5.0.0 binds 0.0.0.0 and has no host parameter"
    }

    /// What the release is said to be read from when only the calls decide it.
    static let fourShapeDetail = "HTTPServerTransport is given authenticator: or oauthServer:, which 5.0.0 removed"
    /// The same, for the 5.x spellings.
    static let fiveShapeDetail = "the source uses host:, listen(host:) or authentication, which 5.0.0 added"
    /// What is printed when nothing decided the release.
    static let assumedDetail = "no requirement, pin or version-specific call found; 5.x assumed"

    /// Comparison operators: a literal compared against is not a literal chosen.
    static let comparisonOperators: Set<String> = ["==", "!=", "===", "!==", "~="]
}
