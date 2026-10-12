import Foundation
import Testing
@testable import QualityGateCore
@testable import SafetyAuditor

/// A host carried into a value and compared is a host question.
///
/// `security.ssrf` clears a request when a question was asked of the URL's host before it. Until
/// 2026-10-08 the only questions it could read were the host compared *directly* and the URL
/// handed to a validator. A same-origin check written as two small `Equatable` values — scheme,
/// host and port copied out of each URL, compared with `==` — was reported, and the author had
/// to respell a correct check to satisfy the rule.
///
/// What this pins: the forms that now count, and the ones that still must not — the host logged,
/// bound and never compared, tested only for presence, or a value that carries the scheme alone.
///
/// See `quality-gate-swift-project/plans/proposals/AURLIsNotARequest.md` §10.
@Suite("SSRF: a host carried into a value and compared")
struct SSRFHostQuestionTests {

    static let rule = "security.ssrf"

    /// The line `body` starts on once ``wrapped(_:)`` has put it in a function.
    static let bodyLine = 47

    /// Types a check can carry a host in, and one function that requests a URL it builds.
    private static func wrapped(_ body: String) -> String {
        """
        import Foundation
        struct Origin: Hashable {
            let scheme: String
            let host: String
            let port: Int
            init(_ url: URL) {
                scheme = url.scheme?.lowercased() ?? ""
                host = url.host?.lowercased() ?? ""
                port = url.port ?? 443
            }
        }
        struct Parsed: Equatable {
            let host: String
            init?(_ url: URL) {
                guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
                self.host = host
            }
        }
        struct Endpoint: Equatable {
            let scheme: String?
            let host: String?
            let port: Int?
        }
        struct SchemeOnly: Equatable {
            let scheme: String
            init(_ url: URL) { scheme = url.scheme ?? "" }
        }
        struct HasHost: Equatable {
            let present: Bool
            init(_ url: URL) { present = url.host != nil }
        }
        func origin(of url: URL) -> String {
            "\\(url.scheme ?? "")://\\(url.host ?? ""):\\(url.port ?? 443)"
        }
        func scheme(of url: URL) -> String { url.scheme ?? "" }
        func noted(_ url: URL) -> Bool {
            logger.info("reading \\(url.host ?? "")")
            return true
        }
        struct Client {
            let session: URLSession
            let expected: Endpoint
            let pinned: (String?, String?)
            let expectedOrigin: String
            let allowedOrigins: Set<Origin>
            func run(input: String, trusted: URL, other: URL) async throws {
        \(body)
            }
        }
        """
    }

    private func findings(_ source: String) async throws -> [Diagnostic] {
        try await SafetyAuditor().auditSource(source, fileName: "test.swift", configuration: Configuration())
            .diagnostics.filter { $0.ruleId == Self.rule }
    }

    private func checked(by check: String) async throws -> [Diagnostic] {
        try await findings(Self.wrapped("""
                guard let url = URL(string: input) else { return }
                \(check)
                _ = try await session.data(from: url)
            """))
    }

    private func across(_ files: [(path: String, source: String)]) -> [Diagnostic] {
        SafetyAuditor.auditRequestFlow(sources: files, configuration: Configuration())
            .diagnostics.filter { $0.ruleId == Self.rule }
    }

    // MARK: - Control

    @Test("Control: with no check at all the fixture's request is reported, on the construction")
    func control() async throws {
        let found = try await checked(by: "")
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == Self.bodyLine)
    }

    // MARK: - What counts

    @Test("A value built from the URL's host and compared is a host question", arguments: [
        // The URL handed whole to an initialiser that stores its host, and the result compared.
        "guard Origin(url) == Origin(trusted) else { return }",
        "guard Origin(url) != Origin(other) else { return }",
        "let origin = Origin(url)\n        guard origin == Origin(trusted) else { return }",
        "let same = Origin(url) == Origin(trusted)\n        if !same { return }",
        "switch Origin(url) { case Origin(trusted): break; default: return }",
        "guard allowedOrigins.contains(Origin(url)) else { return }",
        // A failable initialiser that binds the host before storing it.
        "guard Parsed(url) == Parsed(trusted) else { return }",
        // The host handed to a memberwise initialiser, the value bound, then compared.
        "let mine = Endpoint(scheme: url.scheme, host: url.host, port: url.port)\n        guard mine == expected else { return }",
        "guard Endpoint(scheme: url.scheme, host: url.host?.lowercased(), port: url.port) == expected else { return }",
        // A tuple.
        "guard (url.scheme, url.host, url.port) == (trusted.scheme, trusted.host, trusted.port) else { return }",
        "let key = (url.scheme, url.host)\n        guard key == pinned else { return }",
        // A function that returns a string made from the host.
        "guard origin(of: url) == origin(of: trusted) else { return }",
        "guard origin(of: url) == expectedOrigin else { return }",
        // The same string written in place.
        #"guard "\(url.scheme ?? "")://\(url.host ?? "")" == expectedOrigin else { return }"#,
    ])
    func carriedAndCompared(check: String) async throws {
        #expect(try await checked(by: check).isEmpty, "\(check)")
    }

    @Test("The host bound to a local is followed through a second binding", arguments: [
        // One step — read before this change, pinned here so the depth is on record.
        #"guard let host = url.host?.lowercased(), host == "api.example.com" else { return }"#,
        // Two steps.
        "guard let host = url.host else { return }\n        let lowered = host.lowercased()\n"
            + #"        guard lowered == "api.example.com" else { return }"#,
        "let raw = url.host\n        let host = raw ?? \"\"\n        if !allowedHosts(host) { return }",
    ])
    func boundThenCompared(check: String) async throws {
        #expect(try await checked(by: check).isEmpty, "\(check)")
    }

    @Test("A question asked of URLComponents made from the URL is asked of the URL", arguments: [
        "let components = URLComponents(url: url, resolvingAgainstBaseURL: false)\n"
            + #"        guard components?.host == "api.example.com" else { return }"#,
        "guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),\n"
            + "              let host = components.host?.lowercased(), allowedNames.contains(host) else { return }",
    ])
    func componentsOfTheURL(check: String) async throws {
        #expect(try await checked(by: check).isEmpty, "\(check)")
    }

    // MARK: - What still does not

    @Test("Mentioning the host is not asking about it", arguments: [
        // Logged.
        #"logger.info("connecting to \(url.host ?? "")")"#,
        #"print("host: \(url.host ?? "nil")")"#,
        // Bound and never compared.
        "let host = url.host?.lowercased()",
        "guard let host = url.host else { return }\n        logger.info(\"\\(host)\")",
        "let host = url.host\n        let lowered = host?.lowercased()\n        record(lowered)",
        // Carried into a value that is never compared.
        "let origin = Origin(url)\n        logger.info(\"\\(origin)\")",
        "let mine = Endpoint(scheme: url.scheme, host: url.host, port: url.port)\n        record(mine)",
        "let key = (url.scheme, url.host)\n        record(key)",
        "_ = origin(of: url)",
    ])
    func mentionedOnly(check: String) async throws {
        #expect(try await checked(by: check).count == 1, "\(check)")
    }

    @Test("Presence and scheme are still not which host — however they are carried", arguments: [
        // The two decisions of §3.5, kept.
        "guard url.host != nil else { return }",
        #"guard url.scheme == "https" else { return }"#,
        // A carried value compared with nil asks whether there is a host.
        "guard Parsed(url) != nil else { return }",
        "guard let parsed = Parsed(url) else { return }\n        record(parsed)",
        // A value that carries the scheme and no host.
        "guard SchemeOnly(url) == SchemeOnly(trusted) else { return }",
        "guard scheme(of: url) == scheme(of: trusted) else { return }",
        "guard (url.scheme, url.port) == (trusted.scheme, trusted.port) else { return }",
        // A value that carries only whether a host exists.
        "guard HasHost(url) == HasHost(trusted) else { return }",
        // A function that logs the host and returns something else.
        "guard noted(url) == true else { return }",
        // A real comparison, about some other URL.
        "guard Origin(other) == Origin(trusted) else { return }",
    ])
    func presenceAndSchemeCarried(check: String) async throws {
        #expect(try await checked(by: check).count == 1, "\(check)")
    }

    @Test("A carried comparison after the request clears nothing")
    func comparedAfter() async throws {
        let found = try await findings(Self.wrapped("""
                guard let url = URL(string: input) else { return }
                _ = try await session.data(from: url)
                guard Origin(url) == Origin(trusted) else { return }
            """))
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == Self.bodyLine)
    }

    // MARK: - The join

    @Test("A function that compares two carried origins is a validator, and the carrier may be in another file")
    func validatorThroughACarrier() {
        func files(_ comparison: String) -> [(path: String, source: String)] {
            [
                (path: "Origin.swift", source: """
                    import Foundation
                    struct Origin: Equatable {
                        let scheme: String
                        let host: String
                        init(_ url: URL) {
                            scheme = url.scheme ?? ""
                            host = url.host ?? ""
                        }
                    }
                    struct SchemeOnly: Equatable {
                        let scheme: String
                        init(_ url: URL) { scheme = url.scheme ?? "" }
                    }
                    """),
                (path: "Fetcher.swift", source: """
                    import Foundation
                    struct Fetcher {
                        let base: URL
                        static func sameOrigin(_ candidate: URL, as trusted: URL) -> Bool {
                            \(comparison)
                        }
                        func fetch(_ text: String) async throws {
                            guard let url = URL(string: text), Self.sameOrigin(url, as: base) else { return }
                            _ = try await URLSession.shared.data(from: url)
                        }
                    }
                    """),
            ]
        }
        #expect(across(files("Origin(candidate) == Origin(trusted)")).isEmpty)
        let schemeOnly = across(files("SchemeOnly(candidate) == SchemeOnly(trusted)"))
        #expect(schemeOnly.count == 1)
        #expect(schemeOnly.first?.filePath == "Fetcher.swift")
        #expect(schemeOnly.first?.lineNumber == 8)
    }

    @Test("A factory that returns a value made from its parameter's host carries it")
    func factoryCarrier() async throws {
        func source(_ factory: String) -> String {
            """
            import Foundation
            struct Site: Equatable {
                let host: String
                let port: Int
                static func of(_ url: URL) -> Site? {
                    \(factory)
                }
            }
            struct Fetcher {
                func fetch(_ text: String, trusted: URL) async throws {
                    guard let url = URL(string: text), Site.of(url) == Site.of(trusted) else { return }
                    _ = try await URLSession.shared.data(from: url)
                }
            }
            """
        }
        #expect(try await findings(source("""
            guard let host = url.host?.lowercased() else { return nil }
                    return Site(host: host, port: url.port ?? 443)
            """)).isEmpty)
        #expect(try await findings(source("""
            guard url.host != nil else { return nil }
                    return Site(host: "fixed", port: url.port ?? 443)
            """)).count == 1)
    }

    // MARK: - The real site

    /// SwiftMCPClient `HTTPSSETransport.swift`, 2026-10-06, as its author first wrote the fix for
    /// the endpoint event: the origin of each URL copied into a private `Equatable` value, and
    /// the two compared. Shape and names as found; bodies trimmed to the statements that matter.
    private static func sseTransport(originCheck: String) -> String {
        """
        import Foundation
        public actor HTTPSSETransport {
            private let url: URL
            private var endpointURL: URL?

            private struct Origin: Equatable {
                let scheme: String
                let host: String
                let port: Int

                init(_ url: URL) {
                    let scheme = url.scheme?.lowercased() ?? ""
                    self.scheme = scheme
                    self.host = url.host?.lowercased() ?? ""
                    self.port = url.port ?? (scheme == "https" ? 443 : 80)
                }
            }

            public func send(_ data: Data) async throws {
                guard let endpointURL = endpointURL, let client = httpClient else {
                    throw MCPError.connectionFailed(reason: "Not connected")
                }
                _ = try await post(data, to: endpointURL, on: client, forcingRefresh: false)
            }

            private func post(
                _ data: Data,
                to endpointURL: URL,
                on client: HTTPClient,
                forcingRefresh: Bool
            ) async throws -> HTTPClientResponse {
                var request = HTTPClientRequest(url: endpointURL.absoluteString)
                request.method = .POST
                request.body = .bytes(data)
                return try await client.execute(request, timeout: connectionTimeout)
            }

            private func read(events: [SSEEvent]) throws {
                for event in events where event.event == "endpoint" {
                    let resolvedEndpoint = try Self.resolveEndpoint(event.data, against: url)
                    self.endpointURL = resolvedEndpoint
                    self.isConnected = true
                }
            }

            static func resolveEndpoint(_ raw: String, against streamURL: URL) throws -> URL {
                guard let resolved = URL(string: raw, relativeTo: streamURL)?.absoluteURL,
                      var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
                    throw MCPError.connectionFailed(reason: "Invalid endpoint URL: \\(raw)")
                }
                components.fragment = nil
                guard let text = components.string, let endpoint = URL(string: text) else {
                    throw MCPError.connectionFailed(reason: "Invalid endpoint URL: \\(raw)")
                }
                guard endpoint.user == nil, endpoint.password == nil else {
                    throw MCPError.endpointRejected(endpoint: text, reason: "credentials in the URL")
                }
        \(originCheck)
                return endpoint
            }
        }
        """
    }

    @Test("SwiftMCPClient HTTPSSETransport — same origin checked by comparing two Equatable values")
    func structEqualityOriginCheck() async throws {
        #expect(try await findings(Self.sseTransport(originCheck: """
                    guard Origin(endpoint) == Origin(streamURL) else {
                        throw MCPError.endpointRejected(endpoint: text, reason: "another origin")
                    }
            """)).isEmpty)
    }

    @Test("SwiftMCPClient HTTPSSETransport — without the comparison it is the finding the rule printed")
    func structEqualityOriginCheckRemoved() async throws {
        let found = try await findings(Self.sseTransport(originCheck: """
                    logger.debug("endpoint on \\(Origin(endpoint).host)")
            """))
        let finding = try #require(found.first)
        #expect(found.count == 1)
        #expect(finding.lineNumber == 52)
        #expect(finding.message.contains("URL built from `text` and returned by `resolveEndpoint(_:against:)`"))
        #expect(finding.message.contains("is stored in `endpointURL`"))
        #expect(finding.message.contains("`post(to:)` → `execute(_:)`"))
    }

    @Test("SwiftMCPClient HTTPSSETransport — the respelling the author settled on still clears")
    func respelledOriginCheck() async throws {
        #expect(try await findings(Self.sseTransport(originCheck: """
                    guard let expectedHost = streamURL.host?.lowercased(), !expectedHost.isEmpty,
                          endpoint.host?.lowercased() == expectedHost else {
                        throw MCPError.endpointRejected(endpoint: text, reason: "another origin")
                    }
            """)).isEmpty)
    }
}
