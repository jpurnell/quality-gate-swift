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

``ServerSurfaceInventory/init(files:targets:guardTypes:dependencies:)`` joins what one file cannot see alone and
sorts every list by site, so the answer does not depend on the order files arrive in.

## What it discovers

**Listeners** (``ServerListener``), each with where it binds (``HostBinding``):

| Framework | Recognised | Address |
|---|---|---|
| SwiftNIO | `bind(host:port:)`; `bind(to:)` and `bind(unixDomainSocketPath:)` in a file that constructs a bootstrap | the literal; or the expression, resolved to the owning type's parameter or property default (`SSHServer.init(host: String = "0.0.0.0")` then `bind(host: host)`) |
| Network.framework | `NWListener(…)` | the `requiredLocalEndpoint = .hostPort(host:…)` in the same body; `.unix(…)` is a Unix socket; none at all is every interface |
| BSD sockets | `sin_addr.s_addr = …` / `sin6_addr = …`, as an assignment or a memberwise argument: always when the value is `INADDR_ANY` / `in6addr_any`, otherwise only in a file that calls `listen(fd, backlog)` | the constant (`INADDR_ANY` is every interface, `INADDR_LOOPBACK` this machine); any other expression is the caller's |
| Vapor | `Application.make(…)`, `Application(…)` in a file importing Vapor | `127.0.0.1`, Vapor's default, unless `…http.server.configuration.hostname` is assigned anywhere in the package |
| SwiftMCPServer | `MCPServer.builder()`; `HTTPServerTransport(…)` constructed outside the package that declares it | depends on the release — see *A library whose facts changed*, below |
| SwiftCLIKit | `SSHServer(…)` constructed outside the package that declares it | the `host:` argument; inherited `0.0.0.0` when there is none |

**Handlers** (``ServerHandler``):

| Framework | Recognised | Auth facts |
|---|---|---|
| Vapor | `get`/`post`/`put`/`patch`/`delete`/`on`/`webSocket` with a handler body, on a receiver that is routes-shaped — a parameter typed `Application` or `RoutesBuilder`, `Application.make(…)`, a `grouped(…)` of one, a `group(…) { r in }` parameter, a binding to any of these | the group lineage, sorted into guards, authenticators and other middleware; `app.middleware.use(…)` in the target; `req.auth.require(…)` in the handler |
| Vapor collections | `register(collection: T())`, and `T`'s `boot(routes:)` in any file | lineage and prefix inherited from the registration; the weaker of two registrations, naming the other; *unknown* when never registered |
| SwiftMCPServer | each `MCPToolHandler` (named by its `MCPTool(name:)`), `MCPResourceProvider`, `MCPPromptProvider`, `MCPHTTPRoute(…)` | `.authenticator(…)` / `.oauthServer(…)` / `.authentication(…)` with an enforcing case, on a builder chain, binding or `MCPServerBuilder` parameter anywhere in the package; `requiresAuthentication:` as written |
| MCP SDK | `withMethodHandler(T.self)` | none in source |
| SwiftNIO | each `case (.METHOD, "path"):` of a `switch` over a pair, in a file importing NIOHTTP1; `channelRead` on a type installed by a `childChannelInitializer` or WebSocket upgrade; `NIOWebSocketServerUpgrader(…)` | none in source — decided in code the recogniser does not read |

**Settings**: ``HostSetting`` for every host literal chosen in source — a bind argument, a
parameter or property default (`@Option` included), an assignment to `hostname`/`host`, a
`host:`/`hostname:`/`bindAddress:` argument — and ``AuthSetting`` for every authentication switch:
an authenticator parameter or property defaulting to `nil`/`.none`/`.unauthenticated`, an
`authRequired`-style flag defaulting to `false`, a flag read from the environment, an authenticator
passed as `nil` — or `authentication: .unauthenticated` — to a listener type, and
`.authentication(.unauthenticated)` on an MCP builder. A listener's ``ListenerAuthentication`` is
what leaves it open first — said so at its construction, a default in its target, an environment
switch — and only then an authenticator written where it is made.

A literal that is compared against (`host == "0.0.0.0"`), listed in an array or dictionary,
subscripted, or written in a comment is not a setting: it chooses nothing.

## A library whose facts changed

SwiftMCPServer 5.0.0 changed what the same call means. Before it, `HTTPServerTransport` wrote
`0.0.0.0` into its own bind, the builder could not set the address, and a transport given neither
`authenticator:` nor `oauthServer:` answered everyone. From it, both bind `127.0.0.1` unless asked
for more, and authentication is one required argument with a case named `.unauthenticated`. A
package may be on either side, so the inventory reads its rows with the release the package
builds against and records it (``ServerSurfaceInventory/libraries``, ``LibraryRelease``):

| In source | Before 5.0.0 | From 5.0.0 |
|---|---|---|
| `MCPServer.builder()`, no host | ``HostBinding/inherited(library:kind:note:)``, every interface — hard-coded in the library | ``HostBinding/frameworkDefault(_:note:)``, loopback |
| `.listen(host: "0.0.0.0")` on the builder | — (does not exist) | ``HostBinding/literal(_:_:)``, every interface; the literal is a ``HostSetting`` of kind `argument` that reaches a listener |
| `.listen(host: options.host)` | — | ``HostBinding/expression(_:defaultValue:)``: the operator's |
| `HTTPServerTransport(…)`, no `host:` | inherited, every interface | framework default, loopback |
| `HTTPServerTransport(host: "0.0.0.0", …)` | — | literal, every interface; a ``HostSetting`` of kind `argument` that reaches a listener |
| `HTTPServerTransport(host: host, …)` | — | expression |
| `authenticator: nil` / `oauthServer: nil` on the transport | ``ListenerAuthentication/explicitlyNone(names:)`` | — (removed) |
| `authentication: .unauthenticated` on the transport; `.authentication(.unauthenticated)` on the builder | — | ``ListenerAuthentication/explicitlyNone(names:)``, and an ``AuthSetting`` of kind `argument` |
| `authentication: .apiKey(…)` / `.oauth(…)` / `.apiKeyOrOAuth(…)`; `.authenticator(…)`, `.oauthServer(…)` on the builder | builder calls: ``ListenerAuthentication/authenticated(by:)`` | ``ListenerAuthentication/authenticated(by:)`` |

**How the release is told**, strongest evidence first (``LibraryRelease/Evidence``):

1. **The manifest requirement**, when it admits one major version — `from:`, `exact:`,
   `.upToNextMajor(from:)`, `.upToNextMinor(from:)`, a range inside one major. It outranks the
   pin: SwiftPM will not build against a pin the manifest excludes, so a stale `Package.resolved`
   is named in the evidence and not believed.
2. **The `Package.resolved` pin**, where the manifest leaves the major open (a branch, a
   revision, a range across majors) or does not name the library, which is how a transitive
   dependency looks.
3. **The calls themselves**, where neither file decides — a `path:` dependency, a single source
   audited alone. `authenticator:` or `oauthServer:` on the transport compiles only before
   5.0.0; `host:`, `listen(host:)` and `authentication` only from it.
4. **Assumed 5.x**, where the calls do not say or say both — and the summary says *assumed*.

Both files are read as text (``PackageDependencies``); nothing is resolved, fetched or built. The
calls are the last resort rather than the first because the commonest consumer —
`MCPServer.builder().tools(…).run()` — is spelled identically in both generations and binds
differently: its shape decides nothing. Anything below major 5 is read with the pre-5 facts.

The release and its evidence are printed in ``ServerSurfaceInventory/summary``:
`SwiftMCPServer read as 4.x (from: "4.4.1" in Package.swift): binds 0.0.0.0 and takes no host`.

## What it does not see

Stated because a table that omits a row looks exactly like a table with nothing to omit.

- **Cross-function route composition.** A `RoutesBuilder` handed to a helper that is not
  `boot(routes:)` has no root, and its routes are not rows.
- **Dynamic registration.** Handlers built from a list (`buildToolHandlers()`), a path that is not
  a literal (recorded as `<dynamic>`), a collection whose type is chosen at runtime.
- **Dispatch written as `if request.path == …`** (VaultMCPWeb). Pinned as a known miss.
- **Handlers behind a BSD socket.** The listener is a row; the `read(2)` loop that parses the
  request is not (swiftMoE's `/v1/chat/completions`).
- **A second listener** opened any other way — Vapor 1's `Droplet()`, Hummingbird, a socket
  whose address is built by `getaddrinfo` — and Vapor's `--hostname` flag, SwiftMCPServer 5's
  `--host` flag, a reverse proxy, a firewall or a launchd environment — anything decided outside
  source. A SwiftMCPServer 5 builder recorded as loopback is loopback *as written*: the unit file
  that starts it with `--host 0.0.0.0` is not source, and the summary says so.
- **A `path:` dependency's release.** There is no requirement and no pin to read, and the
  dependency's own checkout is another package. The calls decide, or 5.x is assumed.
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

### Library releases

- ``LibraryRelease``
- ``PackageDependencies``

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
