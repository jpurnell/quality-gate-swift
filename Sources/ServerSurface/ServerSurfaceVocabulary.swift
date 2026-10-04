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

    /// Names an authenticator or authoriser is passed under; off when `nil` or `.none`.
    ///
    /// `apiKey`, `apiKeys` and `credentials` from the proposal's list are not here: their
    /// "empty" default is `[]`, and SwiftMCPServer's `APIKeyAuthenticator(apiKeys: [])` with
    /// `authRequired: true` rejects every request — an empty credential list is closed, not off.
    static let authenticatorNames: Set<String> = [
        "auth", "authenticator", "authentication", "authorizer", "oauthServer", "tokenValidator",
    ]

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

    /// What each known listener type does with its address when the caller says nothing.
    static let knownListenerNotes: [String: String] = [
        "HTTPServerTransport": "HTTPServerTransport binds 0.0.0.0 and has no host parameter",
        "SSHServer": "SSHServer binds 0.0.0.0 unless host: is passed",
    ]

    /// Types whose authenticator arguments decide a listener's authentication, beyond the
    /// package's own listener-owning types.
    static let knownAuthCarriers: Set<String> = ["HTTPServerTransport", "SSHServer", "SSHConfiguration"]

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

    /// The note on a `MCPServer.builder()` chain.
    static let mcpBuilderNote = "HTTPServerTransport binds 0.0.0.0 and the builder cannot set the address"

    /// Comparison operators: a literal compared against is not a literal chosen.
    static let comparisonOperators: Set<String> = ["==", "!=", "===", "!==", "~="]
}
