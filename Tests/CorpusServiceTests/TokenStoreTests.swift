import Foundation
import Testing
@testable import CorpusService

/// Phase 3b §2 — bearer tokens v1, deliberately boring.
///
/// Tokens are random 32-byte values shown once at issuance and stored
/// hashed (SHA-256). The raw token must never touch disk.
@Suite("TokenStore")
struct TokenStoreTests {

    private let issuedAt = Date(timeIntervalSince1970: 1_752_000_000)
    private let laterAt = Date(timeIntervalSince1970: 1_752_000_600)

    private func makeStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-service-tests-\(UUID().uuidString)")
            .appendingPathComponent("tokens.json")
            .path
    }

    @Test("issue returns a 64-character lowercase hex token")
    func issueReturnsHexToken() async throws {
        let store = TokenStore(storePath: makeStorePath())
        let token = try await store.issue(name: "ci-bot", now: issuedAt)
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("the raw token is never persisted; its hash is")
    func rawTokenNeverPersisted() async throws {
        let path = makeStorePath()
        let store = TokenStore(storePath: path)
        let token = try await store.issue(name: "ci-bot", now: issuedAt)

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!contents.contains(token))

        let issued = await store.list()
        guard let first = issued.first else {
            Issue.record("expected one issued token, list was empty")
            return
        }
        #expect(contents.contains(first.hashPrefix))
        #expect(contents.contains("ci-bot"))
    }

    @Test("verify round-trips the identity name for a live token")
    func verifyRoundTrip() async throws {
        let store = TokenStore(storePath: makeStorePath())
        let token = try await store.issue(name: "jordan", now: issuedAt)
        let name = await store.verify(token: token, now: laterAt)
        #expect(name == "jordan")
    }

    @Test("verify returns nil for a token that was never issued")
    func verifyWrongTokenIsNil() async throws {
        let store = TokenStore(storePath: makeStorePath())
        _ = try await store.issue(name: "jordan", now: issuedAt)
        let name = await store.verify(
            token: String(repeating: "0", count: 64), now: laterAt)
        #expect(name == nil)
    }

    @Test("a revoked token no longer verifies")
    func revokedTokenIsNil() async throws {
        let store = TokenStore(storePath: makeStorePath())
        let token = try await store.issue(name: "jordan", now: issuedAt)
        try await store.revoke(name: "jordan", now: issuedAt)
        let name = await store.verify(token: token, now: laterAt)
        #expect(name == nil)
    }

    @Test("issuing a duplicate active name throws")
    func duplicateActiveNameThrows() async throws {
        let store = TokenStore(storePath: makeStorePath())
        _ = try await store.issue(name: "ci-bot", now: issuedAt)
        await #expect(throws: TokenStoreError.duplicateActiveName("ci-bot")) {
            _ = try await store.issue(name: "ci-bot", now: self.laterAt)
        }
    }

    @Test("a revoked name may be reissued")
    func revokedNameMayBeReissued() async throws {
        let store = TokenStore(storePath: makeStorePath())
        _ = try await store.issue(name: "ci-bot", now: issuedAt)
        try await store.revoke(name: "ci-bot", now: issuedAt)
        let token = try await store.issue(name: "ci-bot", now: laterAt)
        let name = await store.verify(token: token, now: laterAt)
        #expect(name == "ci-bot")
    }

    @Test("revoking an unknown name throws")
    func revokeUnknownThrows() async throws {
        let store = TokenStore(storePath: makeStorePath())
        await #expect(throws: TokenStoreError.unknownName("ghost")) {
            try await store.revoke(name: "ghost", now: self.issuedAt)
        }
    }

    @Test("revoking an already-revoked name throws")
    func doubleRevokeThrows() async throws {
        let store = TokenStore(storePath: makeStorePath())
        _ = try await store.issue(name: "ci-bot", now: issuedAt)
        try await store.revoke(name: "ci-bot", now: issuedAt)
        await #expect(throws: TokenStoreError.alreadyRevoked("ci-bot")) {
            try await store.revoke(name: "ci-bot", now: self.laterAt)
        }
    }

    @Test("list shows names and 12-hex prefixes only, sorted by issuedAt")
    func listShowsPrefixesSortedByIssuedAt() async throws {
        let store = TokenStore(storePath: makeStorePath())
        _ = try await store.issue(name: "second", now: laterAt)
        _ = try await store.issue(name: "first", now: issuedAt)

        let issued = await store.list()
        #expect(issued.map(\.name) == ["first", "second"])
        #expect(issued.map(\.issuedAt) == [issuedAt, laterAt])
        for entry in issued {
            #expect(entry.hashPrefix.count == 12)
            #expect(entry.hashPrefix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(entry.revokedAt == nil)
        }
    }

    @Test("the store persists across reopen")
    func persistsAcrossReopen() async throws {
        let path = makeStorePath()
        let token: String
        do {
            let store = TokenStore(storePath: path)
            token = try await store.issue(name: "jordan", now: issuedAt)
        }

        let reopened = TokenStore(storePath: path)
        let name = await reopened.verify(token: token, now: laterAt)
        #expect(name == "jordan")

        let issued = await reopened.list()
        #expect(issued.map(\.name) == ["jordan"])
        #expect(issued.map(\.issuedAt) == [issuedAt])
    }

    @Test("a missing store file is an empty store")
    func missingFileIsEmptyStore() async {
        let store = TokenStore(storePath: makeStorePath())
        let issued = await store.list()
        #expect(issued == [])
    }
}
