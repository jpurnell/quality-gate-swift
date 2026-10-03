# ``ServerSurface``

What a package exposes to a network: every listener and every handler, read from source, as data
rules can consume.

## Overview

A server's attack surface is two questions asked many times: *where does it listen*, and *what
answers when something arrives*. Nothing in the gate could answer either. `AHandlerSaysWhoMayCallIt.md`
went looking for "how many handlers have something in front of them" across six servers and could
not answer it from source for five; `AHandlerThatAnyoneCanCall.md` found six sockets bound to
`0.0.0.0`, none with a comment saying why. Three further proposals add columns to the same table.
This module is that table.

It is built in two steps so a checker that already walks every file pays for one more visitor and
no second parse:

```swift
import ServerSurface
import SwiftParser
import SwiftSyntax

let source = """
    import Vapor
    func routes(_ app: Application) throws {
        app.post("v1", "runway") { request in "ok" }
    }
    """
let tree = Parser.parse(source: source)
let converter = SourceLocationConverter(fileName: "Sources/App/routes.swift", tree: tree)
let facts = ServerSurfaceFileFacts.collect(from: tree, converter: converter,
                                           fileName: "Sources/App/routes.swift")
let inventory = ServerSurfaceInventory(files: [facts])
let row = inventory.handlers[0]   // POST /v1/runway, verdict .none
```

``ServerSurfaceInventory/init(files:targets:guardTypes:)`` joins what one file cannot see alone and
sorts every list by site, so the answer does not depend on the order files arrive in.

## What it discovers

**Listeners** (``ServerListener``), each with where it binds (``HostBinding``):

| Framework | Recognised | Address |
|---|---|---|
| SwiftNIO | `bind(host:port:)`; `bind(to:)` and `bind(unixDomainSocketPath:)` in a file that constructs a bootstrap | the literal; or the expression, resolved to the owning type's parameter or property default (`SSHServer.init(host: String = "0.0.0.0")` then `bind(host: host)`) |
| Network.framework | `NWListener(…)` | the `requiredLocalEndpoint = .hostPort(host:…)` in the same body; `.unix(…)` is a Unix socket; none at all is every interface |
| Vapor | `Application.make(…)`, `Application(…)` in a file importing Vapor | `127.0.0.1`, Vapor's default, unless `…http.server.configuration.hostname` is assigned anywhere in the package |
| SwiftMCPServer | `MCPServer.builder()`; `HTTPServerTransport(…)` and `SSHServer(…)` constructed outside the package that declares them | inherited: the library binds `0.0.0.0` and the caller cannot narrow it |

**Handlers** (``ServerHandler``):

| Framework | Recognised | Auth facts |
|---|---|---|
| Vapor | `get`/`post`/`put`/`patch`/`delete`/`on`/`webSocket` with a handler body, on a receiver that is routes-shaped — a parameter typed `Application` or `RoutesBuilder`, `Application.make(…)`, a `grouped(…)` of one, a `group(…) { r in }` parameter, a binding to any of these | the group lineage, sorted into guards, authenticators and other middleware; `app.middleware.use(…)` in the target; `req.auth.require(…)` in the handler |
| Vapor collections | `register(collection: T())`, and `T`'s `boot(routes:)` in any file | lineage and prefix inherited from the registration; the weaker of two registrations, naming the other; *unknown* when never registered |
| SwiftMCPServer | each `MCPToolHandler` (named by its `MCPTool(name:)`), `MCPResourceProvider`, `MCPPromptProvider`, `MCPHTTPRoute(…)` | `.authenticator(…)` / `.oauthServer(…)` on a builder chain, binding or `MCPServerBuilder` parameter anywhere in the package; `requiresAuthentication:` as written |
| MCP SDK | `withMethodHandler(T.self)` | none in source |
| SwiftNIO | each `case (.METHOD, "path"):` of a `switch` over a pair, in a file importing NIOHTTP1; `channelRead` on a type installed by a `childChannelInitializer` or WebSocket upgrade; `NIOWebSocketServerUpgrader(…)` | none in source — decided in code the recogniser does not read |

**Settings**: ``HostSetting`` for every host literal chosen in source — a bind argument, a
parameter or property default (`@Option` included), an assignment to `hostname`/`host`, a
`host:`/`hostname:`/`bindAddress:` argument — and ``AuthSetting`` for every authentication switch:
an authenticator parameter or property defaulting to `nil`/`.none`, an `authRequired`-style flag
defaulting to `false`, a flag read from the environment, an authenticator passed as `nil` to a
listener type. A listener's ``ListenerAuthentication`` is drawn from the settings in its target.

A literal that is compared against (`host == "0.0.0.0"`), listed in an array or dictionary,
subscripted, or written in a comment is not a setting: it chooses nothing.

## What it does not see

Stated because a table that omits a row looks exactly like a table with nothing to omit.

- **Cross-function route composition.** A `RoutesBuilder` handed to a helper that is not
  `boot(routes:)` has no root, and its routes are not rows.
- **Dynamic registration.** Handlers built from a list (`buildToolHandlers()`), a path that is not
  a literal (recorded as `<dynamic>`), a collection whose type is chosen at runtime.
- **Dispatch written as `if request.path == …`** (VaultMCPWeb). Pinned as a known miss.
- **A second listener** opened any other way, and Vapor's `--hostname` flag, a reverse proxy, a
  firewall or a launchd environment — anything decided outside source.
- **Whether a guard is right** — the wrong user type, the wrong role, object-level access.

Names are matched exactly: a looser `*auth*` pattern matched `author` and `authority` nine times
in thirteen across the portfolio. An empty credential list (`apiKeys: []`) is not "off": with
authentication required it rejects everyone.

## Adding a column

Later proposals add columns rather than reshape rows. ``ServerSurfaceColumn`` names the planned
ones — ``ServerSurfaceColumn/bodyCeiling``, ``ServerSurfaceColumn/admission``,
``ServerSurfaceColumn/credential``, ``ServerSurfaceColumn/cors``,
``ServerSurfaceColumn/responseHeaders``, ``ServerSurfaceColumn/errorDetail`` — and a rule writes
its cell with ``ServerSurfaceInventory/setColumn(_:to:forHandlerAt:)`` against the site the row
already carries.

## Topics

### The inventory

- ``ServerSurfaceInventory``
- ``ServerSurfaceFileFacts``
- ``SourceSite``

### Listeners

- ``ServerListener``
- ``HostBinding``
- ``HostAddressKind``
- ``HostDefault``
- ``ListenerAuthentication``

### Handlers

- ``ServerHandler``
- ``HandlerKind``
- ``HandlerAuth``
- ``HandlerAuthVerdict``
- ``ServerFramework``

### Settings

- ``HostSetting``
- ``AuthSetting``

### Columns

- ``ServerSurfaceColumn``
- ``ColumnValue``
