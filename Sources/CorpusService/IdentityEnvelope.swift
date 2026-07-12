import CorpusKit
import Foundation

/// The identity envelope carried by every corpus write (Phase 3b §2).
///
/// `verifiedIdentity` is attested — by a bearer token or a Phase 2 CI
/// identity. The asserted fields are kept alongside it as what they are:
/// claims. Historical artifacts stay meaningful; new ones gain provenance.
public struct IdentityEnvelope: Sendable, Codable, Equatable {

    /// The attested identity: a token's bound name, or
    /// `"ci:<provider>:<actor>"` from a CI attestation, or `nil` when the
    /// write carries claims only.
    public let verifiedIdentity: String?
    /// The owner the writer claims (config string) — a claim, not proof.
    public let assertedOwner: String
    /// The host the writer claims to run on — a claim, not proof.
    public let assertedHost: String?

    /// Creates an identity envelope.
    /// - Parameters:
    ///   - verifiedIdentity: The attested identity, or `nil` for claims only.
    ///   - assertedOwner: The owner claim from configuration.
    ///   - assertedHost: The host claim, if the writer provides one.
    public init(verifiedIdentity: String?, assertedOwner: String, assertedHost: String?) {
        self.verifiedIdentity = verifiedIdentity
        self.assertedOwner = assertedOwner
        self.assertedHost = assertedHost
    }

    /// Resolves the envelope for a write, strongest attestation first.
    ///
    /// Order: a token verified against `store` wins; else a Phase 2 CI
    /// identity (`"ci:<provider>:<actor>"`); else the envelope is
    /// nil-verified and carries the asserted claims only. The claims are
    /// preserved in every case.
    /// - Parameters:
    ///   - token: The presented bearer token, if any.
    ///   - store: The token store to verify against, if one is configured.
    ///   - ciIdentity: The CI attestation for this run, if detected.
    ///   - assertedOwner: The owner claim from configuration.
    ///   - assertedHost: The host claim, if the writer provides one.
    ///   - now: The resolution timestamp (checked against revocation).
    /// - Returns: The resolved envelope.
    public static func resolve(
        token: String?,
        store: TokenStore?,
        ciIdentity: CIIdentity?,
        assertedOwner: String,
        assertedHost: String?,
        now: Date
    ) async -> IdentityEnvelope {
        if let token, let store,
           let name = await store.verify(token: token, now: now) {
            return IdentityEnvelope(
                verifiedIdentity: name,
                assertedOwner: assertedOwner,
                assertedHost: assertedHost)
        }
        if let ciIdentity {
            return IdentityEnvelope(
                verifiedIdentity: "ci:\(ciIdentity.provider):\(ciIdentity.actor)",
                assertedOwner: assertedOwner,
                assertedHost: assertedHost)
        }
        return IdentityEnvelope(
            verifiedIdentity: nil,
            assertedOwner: assertedOwner,
            assertedHost: assertedHost)
    }
}
