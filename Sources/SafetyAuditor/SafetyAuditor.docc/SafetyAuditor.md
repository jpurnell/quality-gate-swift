# ``SafetyAuditor``

Scans Swift source files for forbidden patterns that could cause crashes in production.

## Overview

SafetyAuditor uses SwiftSyntax to parse and analyze Swift source code, detecting patterns that could lead to runtime crashes. Unlike compiler warnings, these checks focus specifically on safety-critical patterns.

### Detected Patterns

| Pattern | Risk | Rule ID |
|---------|------|---------|
| `value!` | Force unwrap crashes if nil | `force-unwrap` |
| `as!` | Force cast crashes if type mismatch | `force-cast` |
| `try!` | Force try crashes if error thrown | `force-try` |
| `fatalError()` | Unconditional crash | `fatal-error` |
| `precondition()` | Crashes in release if false | `precondition` |
| `assertionFailure()` | Crashes in debug builds | `assertion-failure` |
| `unowned` | Crashes if accessed after deallocation | `unowned` |
| `while true` | Potential infinite loop | `infinite-loop` |

### Security rules

The same pass runs the `security.*` rules. Their CWE lists and OWASP columns live in
``SecurityRuleManifest``; the severity here is what a finding is reported at.

| Rule ID | Severity | CWE | What it detects |
|---------|----------|-----|-----------------|
| `security.hardcoded-secret` | warning | 798 | Secret-named variable assigned a string literal |
| `security.command-injection` | error | 78 | A shell run with `-c` and a command string assembled at runtime |
| `security.weak-crypto` | warning | 328 | MD5 / SHA-1 hashing |
| `security.insecure-transport` | warning | 319 | `http://` URLs other than local hosts |
| `security.eval-js` | error | 95 | `evaluateJavaScript` with dynamic input |
| `security.sql-injection` | error | 89 | Interpolation in an SQL-executing call |
| `security.insecure-keychain` | warning | 922 | Keychain items readable while the device is locked |
| `security.tls-disabled` | error | 295, 298 | Certificate validation disabled or weakened |
| `security.path-traversal` | warning | 22 | A chosen segment joined onto a directory and used unchecked |
| `security.path-containment-by-prefix` | error | 22, 187 | A containment check written as a prefix with no separator |
| `security.archive-path-escape` | error | 22 | An archive entry's name joined onto a destination and written unchecked; `unzip -:`, `tar -P` |
| `security.archive-symlink` | error | 59 | A link whose target an archive entry chose, created unchecked; ZIPFoundation's symlink check switched off |
| `security.regex-catastrophic` | error | 1333 | A literal pattern with nested or overlapping unbounded repetition |
| `security.regex-from-input` | warning | 1333 | A pattern derived from external input |
| `security.predicate-injection` | error | 943, 917 | An `NSPredicate` / `NSExpression` format string assembled at runtime |
| `security.ssrf` | warning (network input: error) | 918 | A URL built from non-literal input that reaches a network request with no check on its host |
| `security.broken-cipher` | error | 327 | DES, 3DES, RC4, RC2, CAST or Blowfish constants; CryptoSwift Blowfish, Rabbit |
| `security.ecb-mode` | error | 327 | ECB mode (`kCCOptionECBMode`, `kCCModeECB`, CryptoSwift `ECB()`) |
| `security.homemade-digest` | warning | 1240 | A digest-named function of a secret that calls no primitive |
| `security.hardcoded-key` | error | 321 | Literal key bytes given to a cipher, MAC or key initialiser; a PEM private key in a literal |
| `security.static-iv` | error | 329, 1204, 323 | A nil or literal IV when encrypting; a literal or held AEAD nonce |
| `security.weak-kdf` | error (unchecked PBKDF2: warning) | 916 | PBKDF2 below 210,000 rounds; a bare SHA-2 digest of a password |
| `security.weak-key-size` | error | 326 | RSA below 2048 bits; a symmetric key below 128 bits |
| `security.xml-external-entities` | error | 611 | An XML parser configured, or defaulted, to load external entities |
| `security.xml-entity-expansion` | warning (`XML_PARSE_HUGE`: error) | 776 | An `XMLDocument` parse with no DTD refusal; `XML_PARSE_HUGE` |
| `security.tls-no-hostname` | error | 297 | A certificate not checked against the host |
| `security.trust-handler-accepts-all` | error | 295 | A trust challenge answered without an evaluation |
| `security.trust-anchors-widened` | warning | 295 | Built-in anchors re-enabled after pinning |
| `security.ats-disabled` | error / warning | 319 | App Transport Security exceptions in `Info.plist` |
| `security.weak-prng` | error | 338 | A security value made by the C `rand` family or GameplayKit |
| `security.seeded-secret` | error | 335, 336, 337 | A security value drawn from a generator seeded in the same function |
| `security.predictable-token` | error | 341 | A security value made only of the clock, the process id or a hash value |
| `security.uuid-as-secret` | warning | 340 | A security value made of `UUID()` |
| `security.bind-all-interfaces` | error (literal at the bind) / warning | 1327 | A listener bound to every interface |
| `security.listener-auth-optional` | warning | 1188 | Authentication off by default, or switchable off from the environment, in a target that listens |

A finding is acknowledged with `// SECURITY: <reason>` on its line or the line above. The reason
must pass the same validator as `concurrency.*` justifications, and an accepted acknowledgement
is recorded as an override rather than dropped.

### Cryptography rules

The security visitor's crypto rules read what a call is *given*, not only what it is called:

| Rule ID | CWE | Severity | What it detects |
|---------|-----|----------|-----------------|
| `security.weak-crypto` | 328 | warning | `CC_MD5`, `CC_SHA1`, `Insecure.MD5` / `Insecure.SHA1` |
| `security.broken-cipher` | 327 | error | DES, 3DES, RC4, RC2, CAST or Blowfish selected by constant; CryptoSwift `Blowfish`, `Rabbit` |
| `security.ecb-mode` | 327 | error | `kCCOptionECBMode`, `kCCModeECB`; CryptoSwift `ECB` as a block mode |
| `security.homemade-digest` | 1240 | warning | A digest-named function of a secret whose body calls no primitive |
| `security.hardcoded-key` | 321 | error | Literal-derived bytes to `SymmetricKey(data:)`, the key of `CCCrypt` / `CCCryptorCreate` / `CCHmac`, a `P256`/`P384`/`P521`/`Curve25519`/`_RSA` `PrivateKey(raw/pem/derRepresentation:)` or a CryptoSwift `key:`; a PEM private key literal with a body |
| `security.static-iv` | 329, 1204, 323 | error | `nil` or literal IV to an encrypting `CCCrypt` / `CCCryptorCreate` outside ECB; `AES._CBC.encrypt` with a literal IV; a literal `AES.GCM` / `ChaChaPoly` nonce; a nonce held in a `static let` or file-scope `let` passed to `seal`; a CryptoSwift literal `iv:` |
| `security.weak-kdf` | 916 | error | `CCKeyDerivationPBKDF` below 210,000 rounds; `unsafeUncheckedRounds:` (warning, error below the floor); `SHA256`/`384`/`512.hash` or `CC_SHA*` of a password-named value |
| `security.weak-key-size` | 326 | error | `kSecAttrKeySizeInBits` below 2048 unless the same literal asks for an EC key; `_RSA` below 2048 bits; `SymmetricKey` below 128 bits |

The two cipher rules stay quiet inside a CommonCrypto call whose operation is literally
`kCCDecrypt`: the reader of a file did not choose its cipher. `static-iv` does the same, and also
ignores `AES._CBC.decrypt` and a nonce rebuilding a `SealedBox` to open. `hardcoded-key` does
not: a key in the source is readable whichever way the call goes. Under
`weakCryptoPolicy: justified`, a `// Justification:` with a real reason on the line above clears
`weak-crypto`, `broken-cipher`, `ecb-mode`, `hardcoded-key` and `static-iv`, and is recorded as an
override.

"Literal-derived" is syntactic: a string, integer-array, `Data(repeating:count:)` or
`Data(count:)` literal, any of those through `Data(…)`, `Array(…)`, `.utf8`, `.data(using:)`,
`Data(base64Encoded:)` or `Data(hexString:)`, or a name bound by a `let` in the same file to one
of those. The `let` is found lexically, so a parameter that shadows a literal constant is not
the constant. A key copied into a buffer and the buffer passed is not seen.

`hardcoded-secret` (CWE-798) reads a name: a secret-named binding assigned a string literal.
`hardcoded-key` (CWE-321, a child of 798) reads a use: literal bytes where a key belongs. When a
secret-named literal is that key — `let apiSecret = "…"` passed to `SymmetricKey(data:)`, or a
PEM private key — only `hardcoded-key` reports it, so one literal is one finding. With
`hardcoded-key` disabled, `hardcoded-secret` reports it as before.

The four key rules do not report in a test target. A known-answer test needs a fixed key, IV
and nonce, a fast test wants few rounds and a small key, and the gate's determinism rules require
a test's inputs to be fixed — so `Tests/` is where a test vector belongs, and moving it there
clears the finding.

### A seed is not a secret

Four rules ask one question of a value that has to be unpredictable — a token, nonce, salt,
session id, key, challenge, verifier, CSRF value, or OTP, or anything written to a header, cookie
or query item: was it made by something predictable? They fire only in a security context as
`SecurityContext` defines it, so a seeded generator in a simulation stays exactly as wanted.

| Rule ID | CWE | Severity | The value is made by |
|---------|-----|----------|----------------------|
| `security.weak-prng` | 338 | error | `rand`, `random()`, `drand48` and the `*rand48` family, `rand_r`; any GameplayKit source or distribution |
| `security.seeded-secret` | 336 literal seed, 337 clock or pid seed, 335 otherwise | error | `using: &g` or `g.next()`, where `g` is bound in the same function to a generator given a `seed:` / `state:` / `seeds:` or an integer literal, or whose type name says it is deterministic (`SplitMix`, `Xoshiro`, `PCG`, `Mock`, `Seeded`…) |
| `security.predictable-token` | 341 | error | Only literals and `Date()`, `.timeIntervalSince1970`, the clocks' `now`, `CFAbsoluteTimeGetCurrent()`, `mach_absolute_time()`, `getpid()`, `processIdentifier`, `hashValue`, `Hasher`, `ObjectIdentifier` |
| `security.uuid-as-secret` | 340 | warning | Only literals and `UUID()` / `NSUUID()` |

"The value" is read by ``SecurityValueSite``: it climbs through conversions (`String(…)`,
`UInt8(truncatingIfNeeded:)`), encoders, interpolation, arithmetic and `map` closures, and
follows a local into the expression that uses it, up to three hops — so
`let bytes = …; return bytes.hexEncoded()` inside `generateToken()` is a token. A source passed
under some other call's label (`issue(name:, now: Date())`) is that call's business. A bare
`Date()` is a time, not a token: the clock is predictable only once it is turned into a string,
an integer or a hash.

Safe, and the form the fix suggests: `SystemRandomNumberGenerator` bound in the function and
passed `using: &g`; `T.random(in:)`; `SecRandomCopyBytes`; `arc4random*`; `SymmetricKey(size:)`;
CryptoKit nonces and private keys. A generator whose origin the function cannot show — a
parameter, a stored property — is counted, not judged.

`uuid-as-secret` is a warning permanently: a v4 UUID is as unpredictable as the alternative on
the platforms checked, and also a type whose specification says not to rely on it. Under
`weakCryptoPolicy: justified` a `// Justification:` on the line above clears it, recorded as an
override; `// SECURITY:` works as for every rule.

`stochastic-no-seed` and `stochastic-global-state` ask for an injectable generator, which is
right for a simulation and the defect for a credential. Where a safe source makes a security
value, they stand down and these rules own the line. Each run prints a
`security.randomness-coverage` note: values examined, safe, weak, predictable, UUID, drawn from
a generator the file cannot resolve, and credential-producing functions that accept a caller's
generator.

### A pattern is a program

A regular expression is a program for a backtracking interpreter: `(a+)+$` takes 27 seconds on an
eighteen-character subject in Swift `Regex`. Three rules read patterns and format strings:

| Rule ID | CWE | Severity | What it detects |
|---------|-----|----------|-----------------|
| `security.regex-catastrophic` | 1333 | error | A literal pattern — at `NSRegularExpression(pattern:)`, `Regex(_:)`, an `of:` passed with `.regularExpression`, a regex literal, or a same-file `let` they name — with a group quantified by `+`/`*`/`{n,}` whose body repeats with no mandatory literal, or whose alternatives overlap |
| `security.regex-from-input` | 1333 | warning | A pattern at the same sites, or an `NSPredicate` `MATCHES` operand, derived from external input: request content, an MCP tool argument, the command line or environment, file or network bytes, a workbook cell |
| `security.predicate-injection` | 943, 917 | error | `NSPredicate(format:)` / `NSExpression(format:)` whose format is interpolated or not a literal |

`regex-catastrophic` is cleared by rewriting: a possessive inner quantifier (`a++`), an atomic
group (`(?>a+)`), or disjoint alternatives. `predicate-injection` is cleared by a literal format
with values passed as `%@` and key paths as `%K`. `regex-from-input` stays a warning — every real
site is a feature whose contract is that someone else writes the pattern — and its
`// SECURITY:` acknowledgement must **name a bound** (a cap, limit, maximum, ceiling, deadline or
timeout): "subject capped at 32,767 characters, pattern at 255" is accepted; "the author is
careful" is not.

"External input" is the shared model in `QualityGateCore` (`ExternalInput`), read off the tree by
the `ExternalInputSyntax` target. It is one function wide: a parameter of a public helper is not
input, so the rule says nothing about a pattern that arrives through one.

### A URL is not a request

`security.ssrf` used to report every `URL(string:)` whose argument was not a literal — which is
every URL a program parses. A forged request needs a request. The rule now reports a URL **built
from non-literal input that reaches a call which opens a connection**, with no question asked
about its host in between:

```swift
import Foundation

enum Feed {
    static let allowedHosts: Set<String> = ["feeds.example.com"]

    // Reported, on the `URL(string:)`: the string chooses the host and nothing asks which.
    static func fetchUnchecked(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { return Data() }
        return try await URLSession.shared.data(from: url).0
    }

    // Not reported: the host is asked about before the request.
    static func fetch(_ address: String) async throws -> Data {
        guard let url = URL(string: address), let host = url.host, allowedHosts.contains(host) else {
            return Data()
        }
        return try await URLSession.shared.data(from: url).0
    }

    // Not reported: parsed for markup, never requested.
    static func anchor(_ address: String) -> String {
        guard let url = URL(string: address) else { return "" }
        return "<a href=\"\(url.absoluteString)\">link</a>"
    }

    // Not reported: the literal fixes the host; the identifier only extends the path.
    static func item(_ identifier: Int) async throws -> Data {
        guard let url = URL(string: "https://feeds.example.com/items/\(identifier)") else { return Data() }
        return try await URLSession.shared.data(from: url).0
    }
}
```

| | recognised |
|---|---|
| **Built** | `URL(string:)`, `URL(string:relativeTo:)`, `URLComponents(string:)`, `HTTPClientRequest(url:)`, `URI(string:)` whose string is not a literal, not an interpolation of same-file string constants, and does not write out its scheme and host before its first dynamic piece |
| **Requested** | `URLSession` `data` / `bytes` / `download` / `upload` / `dataTask` / `downloadTask` / `uploadTask` / `webSocketTask` `(from:` / `for:` / `with:)`; `Data` / `String` / `NSData` / `XMLParser(contentsOf:)`; AsyncHTTPClient `execute(_:)` on an `HTTPClientRequest`; `WKWebView.load(_:)` on a `URLRequest`; `WebSocket.connect(to:)`; `NWConnection(to: .url(…))` |
| **Followed** | `let` / `guard let` / `if let` / `for` bindings in the function; `URLRequest(url:)`; `.absoluteURL`, `appendingPathComponent(_:)` and the like; closures inside the function |
| **Cleared by** | the URL's `host` compared with something other than `nil`, tested with `contains` / `hasSuffix` / `hasPrefix`, switched on, or handed to a function inside a condition — before the request. Or the URL handed, in a condition or a `try` statement, to a function of the package that does one of those |

A file URL (`URL(fileURLWithPath:)`, `URL(filePath:)`) is never an operand, so
`Data(contentsOf:)` on a path is not this rule's business. `url.host != nil` and
`url.scheme == "https"` are not host checks: they do not say *which* host.

**The request is usually in a wrapper.** So, like the server-surface rules below, this one is a
package-wide question answered per site. Each file contributes what its functions do with
URL-shaped values, and a join over the package finds the parameters and properties that are
*requested*: `MJPEGStream(url:)` is a sink because a method of `MJPEGStream` hands `url` to
`dataTask(with:)`; `fetch(url:)` is not one if it validates the host before it requests. A built
URL passed to the first is reported where it was built, naming the wrapper and the sink behind
it. Calls are matched to declarations by name and label — there are no types here — so two
unrelated functions with one name are one function to the join.

The join follows a URL out of a function as well as into one. A function that **returns** a URL
it built is a producer: if it builds from its own input, a caller that requests the result makes
the construction a finding, there; if it builds from the string one of its parameters holds —
`func parsed(_ string: String) -> URL?` — each caller's argument decides, so `parsed("https://…")`
is nothing and `parsed(text)` is reported at the call. A producer that checks the host before it
returns is not one.

A URL that is returned, compared, displayed, written into markup, or stored where nothing in the
package requests it is not reported. Not seen: a request made in another *package*, a connection
to a host string (`connect(host:port:)`), a URL assembled by assignment (`components.host = …`),
and a producer called as a method on some other value.

The finding is a **warning**. It is an **error** when the URL derives from request content, an
MCP tool argument or bytes from the network (`ExternalInput`, as for `regex-from-input` above): a
remote party chose where this process connects. The message names the input and the sink, and a
`// SECURITY: <reason>` on the construction's line or the one above acknowledges it as for every
other security rule.

### What a client agrees to trust

Five security rules cover certificate validation and transport policy. The four that read Swift
report through the same `// SECURITY: <reason>` acknowledgement as every other security rule;
`security.ats-disabled` reads a property list instead.

| Rule ID | CWE | Severity | Detects |
|---------|-----|----------|---------|
| `security.tls-disabled` | 295, 298 | error | A client's `certificateVerification` set or passed as `.none`, including either arm of a ternary and a typed local; `SecTrustSetExceptions`; Alamofire's `DisabledTrustEvaluator`; `allowsExpiredCertificates`/`allowsExpiredRoots` set to `true` |
| `security.tls-no-hostname` | 297 | error | `.noHostnameVerification` on a client configuration; an evaluator built with `validateHost: false`; `SecPolicyCreateSSL(true, nil)`; a basic X.509 policy given to `SecTrustSetPolicies` |
| `security.trust-handler-accepts-all` | 295 | error | A `urlSession`/`webView` challenge handler answering `.useCredential` with `URLCredential(trust:)` and using the result of no evaluation; a `sec_protocol_options_set_verify_block` closure that always completes `true` |
| `security.trust-anchors-widened` | 295 | warning | `SecTrustSetAnchorCertificatesOnly(_, false)`, which undoes pinning |
| `security.ats-disabled` | 319 | error / warning | App Transport Security exceptions in `Info.plist` |

A server configuration is exempt from both mode findings. There `certificateVerification`
governs *client* certificates: `.none` is NIOSSL's default for a server not doing mutual TLS,
and `.noHostnameVerification` is what its own `makeServerConfigurationWithMTLS` sets, since a
server has no hostname to compare a client certificate against.

`security.ats-disabled` reads every `Info.plist` (and `*-Info.plist`) the safety walk reaches,
XML or binary. `NSAllowsArbitraryLoads` is an error, or a warning when a key that makes the
system ignore it is also present. Arbitrary loads in web content or for media, an exception
domain allowing cleartext HTTP, and an exception domain's minimum TLS version below 1.2 are
warnings. A property list keeps no comments, so an insecure domain is acknowledged in
configuration instead, and recorded as an override:

```yaml
security:
  atsAllowedInsecureDomains:
    - legacy.example.com
```

There is no acknowledgement for the global key. An app that needs it removes
`security.ats-disabled` from `enabledRules`, in a file with history.

### Who can connect

Two rules read the package's server-surface inventory (the `ServerSurface` module): every
listener and the address it binds, every handler and what stands in front of it. They are
package-wide questions — whether a `host` default is a bind address depends on whether the
package opens a socket, and whether an authenticator defaulting to `nil` matters depends on
whether its *target* does — so they run once the walk has seen every file, and each finding is
then reported, and acknowledged, in its own file.

| Rule ID | CWE | Severity | Detects |
|---------|-----|----------|---------|
| `security.bind-all-interfaces` | 1327 | error | `"0.0.0.0"`, `"::"`, `"[::]"` or `""` as the host of a `bind`, or of the `.hostPort` a `requiredLocalEndpoint` is set to; `INADDR_ANY` / `in6addr_any` as the address of a `sockaddr_in` / `sockaddr_in6`: a caller cannot narrow it |
| `security.bind-all-interfaces` | 1327 | warning | The same literal as a `host`-named parameter or property default (`@Option` included), an assignment to `hostname`/`host`, or a `host:`/`hostname:`/`bindAddress:` argument that reaches a listener — SwiftMCPServer 5's `HTTPServerTransport(host: "0.0.0.0", …)` and `.listen(host: "0.0.0.0")` on an `MCPServer.builder()` included; an `NWListener` with no `requiredLocalEndpoint` |
| `security.listener-auth-optional` | 1188 | warning | In a target that opens a listener: an authenticator parameter or property defaulting to `nil`/`.none`, an `authRequired`-style flag defaulting to `false`, a flag read from the environment; anywhere, an authenticator passed as `nil` — or SwiftMCPServer 5's `authentication: .unauthenticated` — to a listener type, and `.authentication(.unauthenticated)` on an `MCPServer.builder()` chain |

A literal that is compared against, listed, subscripted or written in a comment chooses nothing
and is not reported. A loopback or non-literal address clears `bind-all-interfaces`; a
non-optional authenticator with no default clears `listener-auth-optional`, as does
`authentication: .apiKey(…)`, `.oauth(…)` or `.apiKeyOrOAuth(…)`. Test targets are not deployments
and are skipped.

**SwiftMCPServer is read by release.** Before 5.0.0 the library bound `0.0.0.0` itself and a
consumer could not narrow it: an `MCPServer.builder()` or `HTTPServerTransport(…)` there is
recorded as inheriting an all-interfaces bind and counted in the coverage note, and is the
library's finding rather than the caller's. From 5.0.0 the same calls bind `127.0.0.1` and are
clean; what is reported is what the caller wrote down:

- `.listen(host: "0.0.0.0")` and `HTTPServerTransport(host: "0.0.0.0", …)` — a **warning**, not an
  error. The error is for a literal at the socket call itself, where the type that owns the
  socket offers no way to narrow it. These are arguments to an API whose parameter *is* the way
  to narrow it — the shape of `TournamentWebSocketServer(host: "0.0.0.0")` — and `listen(host:)`
  is further overridden by `--host` at launch, so it is a default in every sense.
- `authentication: .unauthenticated` and `.authentication(.unauthenticated)` — a **warning**,
  worded and graded as `authenticator: nil` to a listener type always was. Running open is a
  named choice in 5.0.0; the rule asks that the reason be named too, with `// SECURITY:` on the
  line above (inside a builder chain, above the `.authentication(…)` line).

Which release applies is read from `Package.swift`, then `Package.resolved`, then the calls, and
is otherwise assumed to be 5.x; the coverage note says which and on what evidence. A `--host`
flag at launch is not source and is not seen.

Each run states what was examined, zeros included, in a `security.server-surface-coverage` note:
listeners and handlers by framework, how many bind every interface, how many have authentication
off by default, the SwiftMCPServer release the listeners were read as (when there is one), and
how many findings were acknowledged.

### What it scans

The whole repository, minus the configured exclusions — not a hardcoded `Sources/`. That
distinction cost real coverage: unguarded force-unwraps in `Tests/`, in `Plugins/`, and at the
package root were never examined, and a test that crashes on a nil takes a suite down exactly as
thoroughly as shipping code takes an app down. Nested packages are skipped: a vendored dependency
with its own `Package.swift` belongs to whoever maintains it.

Every run prints a `safety.coverage` note with the number of files actually examined. That number
is computed rather than claimed, which is the point — a scope written into prose goes stale
silently, and this one had.

### Exemptions

Code that intentionally uses these patterns can be marked with `// SAFETY:` comments:

```swift
final class SubmitButton {}

let optional: Int? = 42
let sender: Any = SubmitButton()

// SAFETY: Guaranteed non-nil after initialization
let value = optional!

let view = sender as! SubmitButton // SAFETY: Type guaranteed by IB connection
```

The exemption comment can appear on the same line or the line immediately above the violation.

### Custom Exemption Patterns

Configure custom exemption patterns via `.quality-gate.yml`:

```yaml
safety_exemptions:
  - "// SAFETY:"
  - "// @unsafe:"
```

## Topics

### Essentials

- ``SafetyAuditor/check(configuration:)``
- ``SafetyAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:ExemptionGuide>
