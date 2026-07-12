import ArgumentParser
import CorpusService
import Foundation

/// `quality-gate corpusd-token` — bearer-token management for the trust
/// service (Phase 3b §2). Deliberately boring: issue prints the token once,
/// the store holds only SHA-256 hashes, list shows names and prefixes.
///
/// Ships ahead of the daemon so tokens exist the day corpusd goes live —
/// the second-writer tripwire has fired (verified CI writer in the corpus),
/// which is exactly the transition these credentials govern.
struct CorpusdToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpusd-token",
        abstract: "Issue, revoke, and list corpusd bearer tokens (shown once, stored hashed).",
        subcommands: [Issue.self, Revoke.self, List.self]
    )

    /// The default token store, beside the rest of the user's gate state.
    static func defaultStorePath() -> String {
        let home = ProcessInfo.processInfo.environment["QUALITY_GATE_HOME"]
            ?? (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.quality-gate"
        return home + "/corpusd/tokens.json"
    }

    struct Issue: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "issue",
            abstract: "Issue a token for a named client. The token is printed once and never stored."
        )

        @Argument(help: "Client name (e.g. 'ci-iconquer', 'laptop-contributor')")
        var name: String

        @Option(name: .long, help: "Token store path")
        var store: String = CorpusdToken.defaultStorePath()

        func run() async throws {
            let tokenStore = TokenStore(storePath: store)
            let token = try await tokenStore.issue(name: name, now: Date())
            print("""
            Token for '\(name)' — shown ONCE, store it now (the file keeps only its hash):

              \(token)

            Deliver out-of-band. Revoke with: quality-gate corpusd-token revoke \(name)
            """)
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "revoke",
            abstract: "Revoke a named client's token."
        )

        @Argument(help: "Client name to revoke")
        var name: String

        @Option(name: .long, help: "Token store path")
        var store: String = CorpusdToken.defaultStorePath()

        func run() async throws {
            let tokenStore = TokenStore(storePath: store)
            try await tokenStore.revoke(name: name, now: Date())
            print("Revoked '\(name)'. Writes presenting its token now fail verification.")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List issued tokens — names and hash prefixes only."
        )

        @Option(name: .long, help: "Token store path")
        var store: String = CorpusdToken.defaultStorePath()

        func run() async throws {
            let tokenStore = TokenStore(storePath: store)
            let tokens = await tokenStore.list()
            guard !tokens.isEmpty else {
                print("No tokens issued. Issue one with: quality-gate corpusd-token issue <name>")
                return
            }
            let formatter = ISO8601DateFormatter()
            for token in tokens {
                let status = token.revokedAt.map { "revoked \(formatter.string(from: $0))" } ?? "active"
                print("  \(token.hashPrefix)  \(token.name)  issued \(formatter.string(from: token.issuedAt))  [\(status)]")
            }
        }
    }
}
