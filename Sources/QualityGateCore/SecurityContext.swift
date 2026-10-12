import Foundation

/// The gate's one definition of "this value has to be unpredictable" (`ASeedIsNotASecret.md`
/// §3.1), shared so that two checkers cannot disagree about who owns a line (§3.6).
///
/// The predicate is **syntactic and decidable**, and it is deliberately free of SwiftSyntax:
/// `QualityGateCore` does not link the parser, and a predicate over plain facts can be tested
/// exhaustively. A visitor reads the facts off the tree and hands them over as a ``Site``.
///
/// ## Definition
///
/// A value is in a security context when one of these holds:
///
/// **(a) Its destination is named for security.** The value initialises or is assigned to a
/// binding, is passed under an argument label, or is returned from a function, and that name —
/// classified by ``SensitiveName/classify(_:restrictedTo:additionalTerms:)`` — has **no descriptor**
/// (`keyName`, `tokenCount`, `sessionExpiry`, `maxTokens`) and
///
/// 1. contains a **strong** term in any security-relevant category (credential, password, key
///    material, security parameter) — `token`, `nonce`, `salt`, `iv`, `sessionID`, `apiKey`…; or
/// 2. contains only a **weak** term (`key`, `state`, `pin`) *and* an enclosing function or type
///    is a security scope (``isSecurityScope(_:)``) — which is how `let state = …` inside
///    `OAuthConnection` is in, and `@State var state` in a view is out.
///
/// **(b) It is the value argument of a header, cookie or query sink** — see ``sink(callee:argumentLabels:)``.
/// No name is needed.
///
/// Nothing else. In particular **an enclosing security scope alone is not sufficient**:
/// `let jitter = drand48()` inside `AuthService.refreshToken()` is not a context
/// (`ASeedIsNotASecret` §5 test 6). Personal data is never a security context.
///
/// ## What the caller decides
///
/// *Which* expression is the value is the rule's business, not this predicate's. The proposal's
/// rule is "the value, not its neighbours": peel `String(…)`, interpolation, `.uuidString`,
/// `.description`, encoders and arithmetic, but a source that is a labelled argument to some
/// *other* call (`issue(name:now: Date())`) is that call's business. A visitor that has decided an
/// expression is the value then reports its destination:
///
/// | syntax | ``Destination`` |
/// |---|---|
/// | `let token = V`, `token = V`, `self.token = V` | `.binding(name: "token")` (terminal name) |
/// | `f(salt: V)` | `.argument(label: "salt")` |
/// | `return V` / implicit return in `func makeNonce()` | `.returned(fromFunction: "makeNonce")` |
/// | `request.setValue(V, forHTTPHeaderField: …)` | `.sink(.httpHeader)` |
///
/// `enclosingFunctions` and `enclosingTypes` are the names of the lexically enclosing function
/// declarations and type declarations (struct, class, enum, actor, extension's extended type),
/// outermost first.
///
/// ## Usage (Wave B)
///
/// A visitor keeps stacks of enclosing function and type names, decides which expression is the
/// value, and asks. For `let state = String(drand48())` inside `OAuthConnection.begin()`:
///
/// ```swift
/// let site = SecurityContext.Site(
///     destination: .binding(name: "state"),
///     enclosingFunctions: ["begin"],
///     enclosingTypes: ["OAuthConnection"])
/// if let verdict = SecurityContext.evaluate(site) {
///     // security.weak-prng reports here, and can say why:
///     // .weakNameInSecurityScope(term: "state", scope: "OAuthConnection")
///     print(verdict)
/// }
///
/// // Clause (b), on a call: the labels as written, `nil` for an unlabelled argument.
/// let labels: [String?] = [nil, "forHTTPHeaderField"]
/// if let sink = SecurityContext.sink(callee: "setValue", argumentLabels: labels) {
///     // The value is the argument at `sink.valueArgumentIndex`; its site is `.sink(sink.kind)`.
///     let isContext = SecurityContext.isSecurityContext(SecurityContext.Site(destination: .sink(sink.kind)))
///     print(isContext)
/// }
/// ```
///
/// `stochastic-no-seed` standing down (§3.6) asks the same `isSecurityContext(_:)` question of the
/// same site, so the two checkers cannot both claim a line, or both miss it.
public enum SecurityContext {

    /// A call whose value argument leaves the process as a credential would.
    public enum Sink: String, Sendable, Hashable, CaseIterable {
        /// `setValue(_:forHTTPHeaderField:)`, `addValue(_:forHTTPHeaderField:)`,
        /// `headers.add(name:value:)`, `headers.replaceOrAdd(name:value:)`.
        case httpHeader
        /// `HTTPCookie(properties:)`.
        case cookie
        /// `URLQueryItem(name:value:)`.
        case urlQuery
    }

    /// A recognised sink call and which argument is its value.
    public struct SinkMatch: Sendable, Equatable {
        /// The kind of sink.
        public let kind: Sink
        /// Index into the call's argument list of the value argument.
        public let valueArgumentIndex: Int
        /// Index of the argument that names what the value is — the header field, the query
        /// item's name — or `nil` for a sink with no name argument (a cookie's properties).
        /// See ``SecurityContext/sinkCarriesSecurityValue(named:)``.
        public let nameArgumentIndex: Int?

        /// Creates a match.
        public init(kind: Sink, valueArgumentIndex: Int, nameArgumentIndex: Int? = nil) {
            self.kind = kind
            self.valueArgumentIndex = valueArgumentIndex
            self.nameArgumentIndex = nameArgumentIndex
        }
    }

    /// Where the value goes.
    public enum Destination: Sendable, Equatable {
        /// Initialises or is assigned to a binding with this (terminal) name.
        case binding(name: String)
        /// Passed under this argument label.
        case argument(label: String)
        /// Returned from the function with this base name.
        case returned(fromFunction: String)
        /// The value argument of a sink.
        case sink(Sink)
    }

    /// The syntactic facts about one value.
    public struct Site: Sendable, Equatable {
        /// Where the value goes.
        public var destination: Destination
        /// Names of the lexically enclosing functions, outermost first.
        public var enclosingFunctions: [String]
        /// Names of the lexically enclosing types, outermost first.
        public var enclosingTypes: [String]

        /// Creates a site.
        public init(destination: Destination, enclosingFunctions: [String] = [], enclosingTypes: [String] = []) {
            self.destination = destination
            self.enclosingFunctions = enclosingFunctions
            self.enclosingTypes = enclosingTypes
        }
    }

    /// Why a site is a security context — for the diagnostic message.
    public enum Verdict: Sendable, Equatable {
        /// Clause (a)1: the destination's name carries this strong term.
        case named(term: String)
        /// Clause (a)2: a weak term, inside this security-named scope.
        case weakNameInSecurityScope(term: String, scope: String)
        /// Clause (b): the value argument of this sink.
        case sink(Sink)
    }

    /// Words that make an enclosing function or type a security scope, beyond the strong
    /// security-relevant vocabulary. `oauth`, `pkce`, `auth`, `credential`, `crypto` are
    /// `ASeedIsNotASecret` §3.1's; the rest spell out "named for auth or crypto" in the words
    /// Swift code actually uses, since `auth` as a whole word does not match `authentication`.
    public static let scopeWords: Set<String> = [
        "oauth", "pkce", "auth", "credential", "crypto",
        "authenticate", "authentication", "authenticator",
        "encrypt", "decrypt", "encryption", "decryption", "cipher", "cryptography",
    ]

    /// Whether a site is a security context.
    public static func isSecurityContext(_ site: Site) -> Bool {
        evaluate(site) != nil
    }

    /// The reason a site is a security context, or `nil` when it is not.
    public static func evaluate(_ site: Site) -> Verdict? {
        let name: String
        switch site.destination {
        case .sink(let kind):
            return .sink(kind)
        case .binding(let bindingName):
            name = bindingName
        case .argument(let label):
            name = label
        case .returned(let function):
            name = function
        }

        let classification = SensitiveName.classify(name)
        guard classification.descriptor == nil else { return nil }

        let relevant = classification.matches.filter { $0.term.category.isSecurityRelevant }
        if let strong = relevant.last(where: { $0.term.strength == .strong }) {
            return .named(term: strong.term.spelling)
        }
        guard let weak = relevant.last else { return nil }
        // `Array(...)` around each half, because `reversed()` offers two viable overloads —
        // `ReversedCollection` from `BidirectionalCollection` and `[Element]` from `Sequence` —
        // and `+` cannot choose between them. Swift 6.4 resolves it; 6.2.4 reports `ambiguous
        // use of 'reversed()'` and fails the build. Nothing platform-specific: the Linux job
        // runs 6.2.4 and was simply the first thing to compile this with an older type checker.
        let scopes = Array(site.enclosingFunctions.reversed())
            + Array(site.enclosingTypes.reversed())
        guard let scope = scopes.first(where: isSecurityScope) else { return nil }
        return .weakNameInSecurityScope(term: weak.term.spelling, scope: scope)
    }

    /// Whether a function or type name marks a security scope: it carries a strong
    /// security-relevant term, or a ``scopeWords`` word — as one word or two adjacent words
    /// (`OAuth` tokenises to `o`, `auth`).
    public static func isSecurityScope(_ name: String) -> Bool {
        let classification = SensitiveName.classify(name)
        if classification.matches.contains(where: { $0.term.strength == .strong && $0.term.category.isSecurityRelevant }) {
            return true
        }
        let words = classification.words
        for index in words.indices {
            if scopeWords.contains(words[index]) { return true }
            if index + 1 < words.count, scopeWords.contains(words[index] + words[index + 1]) { return true }
        }
        return false
    }

    /// Recognises a header, cookie or query sink by its callee's base name and argument labels
    /// (`nil` for an unlabelled argument), exactly as `ASeedIsNotASecret` §3.1(b) lists them.
    public static func sink(callee: String, argumentLabels labels: [String?]) -> SinkMatch? {
        let headerValueLabels: [String?] = [nil, "forHTTPHeaderField"]
        let nameValueLabels: [String?] = ["name", "value"]
        let propertiesLabels: [String?] = ["properties"]
        // A `where` clause binds only the last pattern of a multi-pattern `case`, so each
        // callee is spelled with its own condition.
        if (callee == "setValue" || callee == "addValue") && labels == headerValueLabels {
            return SinkMatch(kind: .httpHeader, valueArgumentIndex: 0, nameArgumentIndex: 1)
        }
        if (callee == "add" || callee == "replaceOrAdd") && labels == nameValueLabels {
            return SinkMatch(kind: .httpHeader, valueArgumentIndex: 1, nameArgumentIndex: 0)
        }
        if callee == "HTTPCookie" && labels == propertiesLabels {
            return SinkMatch(kind: .cookie, valueArgumentIndex: 0)
        }
        if callee == "URLQueryItem" && labels == nameValueLabels {
            return SinkMatch(kind: .urlQuery, valueArgumentIndex: 1, nameArgumentIndex: 0)
        }
        return nil
    }

    /// Whether a header or query sink with this name carries a security value.
    ///
    /// A sink is a destination for a *named* thing, and the name says what the thing is.
    /// `URLQueryItem(name: "period1", …)` and `forHTTPHeaderField: "If-Modified-Since"` send a
    /// date; `name: "token"` and `"Authorization"` send a credential. So a name written as a
    /// literal decides it: the sink is a context only when the name carries a strong security
    /// word (``SensitiveName``; a weak word such as `state` or `key` alone is not enough, and
    /// personal data is not a security context).
    ///
    /// `nil` — the name is not a literal, so it cannot be read — keeps the sink in context:
    /// an unreadable name is not evidence that the value is harmless.
    ///
    /// This narrows `ASeedIsNotASecret` §3.1(b), which put every sink value in context. That
    /// reported BusinessMathMarketData's Yahoo Finance URL as a predictable token for sending
    /// two timestamps as a date range.
    public static func sinkCarriesSecurityValue(named name: String?) -> Bool {
        guard let name else { return true }
        return SensitiveName.classify(name).categories.contains(where: \.isSecurityRelevant)
    }
}
