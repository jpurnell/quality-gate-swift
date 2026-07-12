import CorpusKit
import Foundation
import Testing
@testable import CorpusService

/// Phase 3b §2 — the identity envelope on every write.
///
/// `verifiedIdentity` comes from a bearer token or a Phase 2 CI identity;
/// the asserted fields are kept alongside it as what they are: claims.
@Suite("IdentityEnvelope")
struct IdentityEnvelopeTests {

    private let now = Date(timeIntervalSince1970: 1_752_000_000)

    private let ciIdentity = CIIdentity(
        provider: "github-actions",
        actor: "quality-gate[bot]",
        workflowRunID: "9876543210",
        commit: "abc123def456",
        repository: "jpurnell/quality-gate-swift")

    private func makeStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-service-tests-\(UUID().uuidString)")
            .appendingPathComponent("tokens.json")
            .path
    }

    @Test("a verified token identity wins over a CI identity")
    func tokenWinsOverCI() async throws {
        let store = TokenStore(storePath: makeStorePath())
        let token = try await store.issue(name: "jordan", now: now)

        let envelope = await IdentityEnvelope.resolve(
            token: token,
            store: store,
            ciIdentity: ciIdentity,
            assertedOwner: "config-owner",
            assertedHost: "roseclub.org",
            now: now)
        #expect(envelope.verifiedIdentity == "jordan")
        #expect(envelope.assertedOwner == "config-owner")
        #expect(envelope.assertedHost == "roseclub.org")
    }

    @Test("a CI identity wins over asserted-only claims")
    func ciWinsOverAssertedOnly() async {
        let envelope = await IdentityEnvelope.resolve(
            token: nil,
            store: nil,
            ciIdentity: ciIdentity,
            assertedOwner: "config-owner",
            assertedHost: nil,
            now: now)
        #expect(envelope.verifiedIdentity == "ci:github-actions:quality-gate[bot]")
        #expect(envelope.assertedOwner == "config-owner")
        #expect(envelope.assertedHost == nil)
    }

    @Test("no token and no CI identity yields claims only")
    func claimsOnlyWhenNothingVerifies() async {
        let envelope = await IdentityEnvelope.resolve(
            token: nil,
            store: nil,
            ciIdentity: nil,
            assertedOwner: "config-owner",
            assertedHost: "laptop.local",
            now: now)
        #expect(envelope.verifiedIdentity == nil)
        #expect(envelope.assertedOwner == "config-owner")
        #expect(envelope.assertedHost == "laptop.local")
    }

    @Test("an unverifiable token falls back to the CI identity")
    func invalidTokenFallsBackToCI() async {
        let store = TokenStore(storePath: makeStorePath())
        let envelope = await IdentityEnvelope.resolve(
            token: String(repeating: "f", count: 64),
            store: store,
            ciIdentity: ciIdentity,
            assertedOwner: "config-owner",
            assertedHost: nil,
            now: now)
        #expect(envelope.verifiedIdentity == "ci:github-actions:quality-gate[bot]")
    }

    @Test("a revoked token no longer verifies an envelope")
    func revokedTokenIsClaimsOnly() async throws {
        let store = TokenStore(storePath: makeStorePath())
        let token = try await store.issue(name: "jordan", now: now)
        try await store.revoke(name: "jordan", now: now)

        let envelope = await IdentityEnvelope.resolve(
            token: token,
            store: store,
            ciIdentity: nil,
            assertedOwner: "config-owner",
            assertedHost: nil,
            now: now.addingTimeInterval(60))
        #expect(envelope.verifiedIdentity == nil)
        #expect(envelope.assertedOwner == "config-owner")
    }
}
