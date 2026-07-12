import CorpusKit
import Foundation
#if canImport(os)
import os
#endif

/// One authenticated write request as it arrives at corpusd (Phase 3b §1).
///
/// Carries the operation plus everything identity resolution needs: the
/// bearer token (when the deployment issues them), the asserted claims, and
/// any Phase 2 CI attestation. A v1 request carries a single identity — a
/// distinct second identity arrives later, through the review queue.
public struct WriteRequest: Sendable {
    /// The write the client wants applied.
    public let operation: CorpusWriteOperation
    /// The presented bearer token, or `nil` when the client has none.
    public let token: String?
    /// The owner the writer claims (config string) — a claim, not proof.
    public let assertedOwner: String
    /// The host the writer claims to run on — a claim, not proof.
    public let assertedHost: String?
    /// The Phase 2 CI attestation for this run, if detected.
    public let ciIdentity: CIIdentity?

    /// Creates a write request.
    /// - Parameters:
    ///   - operation: The write the client wants applied.
    ///   - token: The presented bearer token, if any.
    ///   - assertedOwner: The owner claim from configuration.
    ///   - assertedHost: The host claim, if the writer provides one.
    ///   - ciIdentity: The CI attestation for this run, if detected.
    public init(
        operation: CorpusWriteOperation,
        token: String? = nil,
        assertedOwner: String,
        assertedHost: String? = nil,
        ciIdentity: CIIdentity? = nil
    ) {
        self.operation = operation
        self.token = token
        self.assertedOwner = assertedOwner
        self.assertedHost = assertedHost
        self.ciIdentity = ciIdentity
    }
}

/// What became of a write request.
public enum WriteOutcome: Sendable, Equatable {
    /// The operation entered the queue; the artifact is applied. Carries
    /// the receipt and the identity envelope the write was attributed to.
    case accepted(QueuedReceipt, identity: IdentityEnvelope)
    /// A governed override without a distinct second identity — recorded
    /// as pending review, visible, never lost. The artifact does NOT reach
    /// the queue until a second identity approves.
    case held(PendingReview)
    /// The request failed authentication or validation; nothing was written.
    case rejected(reason: String)
}

/// Typed failures from ``GovernedWriteHandler`` post-approval operations.
public enum GovernedWriteError: Error, Sendable, Equatable {
    /// ``GovernedWriteHandler/applyApproved(_:operation:)`` was handed a
    /// review that is not in the approved state.
    case reviewNotApproved(String)
}

/// The validation pipeline in front of the write queue (Phase 3b §1):
/// authenticated request → validation → queue.
///
/// Rules, in order: when a ``TokenStore`` is configured, a missing or
/// unverifiable token is rejected — auth is on when auth exists (solo mode,
/// `tokens == nil`, passes asserted identity through: today's behavior).
/// The identity envelope is then resolved, the operation's declared project
/// is checked against the artifact's own, and overrides governed by the
/// ``ReviewPolicy`` are held in the ``ReviewQueue`` — the artifact reaches
/// the queue only after a distinct second identity approves.
public struct GovernedWriteHandler: Sendable {

    private static let logger = Logger(
        subsystem: "com.quality-gate", category: "GovernedWriteHandler")

    private let queue: CorpusWriteQueue
    private let tokens: TokenStore?
    private let reviews: ReviewQueue
    private let policy: ReviewPolicy?

    /// Creates a handler over the queue and its governance stores.
    /// - Parameters:
    ///   - queue: The single-writer queue accepted operations enter.
    ///   - tokens: The token store, or `nil` for solo mode (no auth).
    ///   - reviews: Where governed overrides are held for a second identity.
    ///   - policy: The resolved review policy, or `nil` when none exists.
    public init(
        queue: CorpusWriteQueue,
        tokens: TokenStore?,
        reviews: ReviewQueue,
        policy: ReviewPolicy?
    ) {
        self.queue = queue
        self.tokens = tokens
        self.reviews = reviews
        self.policy = policy
    }

    /// Runs a request through the pipeline: auth → identity → schema
    /// validation → review policy → queue.
    /// - Parameters:
    ///   - request: The authenticated write request.
    ///   - now: The evaluation timestamp (token revocation, review records,
    ///     receipts).
    /// - Returns: ``WriteOutcome/accepted(_:identity:)``,
    ///   ``WriteOutcome/held(_:)``, or ``WriteOutcome/rejected(reason:)``.
    public func handle(_ request: WriteRequest, now: Date = Date()) async -> WriteOutcome {
        // (a) Auth is on when auth exists.
        if let tokens {
            guard let token = request.token,
                  await tokens.verify(token: token, now: now) != nil else {
                return .rejected(reason: "authentication required: missing or unverifiable bearer token")
            }
        }

        // (b) Resolve the identity envelope, strongest attestation first.
        let identity = await IdentityEnvelope.resolve(
            token: request.token,
            store: tokens,
            ciIdentity: request.ciIdentity,
            assertedOwner: request.assertedOwner,
            assertedHost: request.assertedHost,
            now: now)

        // (c) Schema validation: declared project must be non-empty and
        // match the artifact's own.
        if let violation = Self.schemaViolation(in: request.operation) {
            return .rejected(reason: violation)
        }

        // (d) Review policy: a governed override in a request that carries
        // no distinct second identity is held until one approves.
        if let policy,
           let governed = Self.firstGovernedOverride(in: request.operation, policy: policy) {
            let submitter = identity.verifiedIdentity ?? identity.assertedOwner
            do {
                let disposition = try await reviews.submit(
                    ruleId: governed.ruleId,
                    justification: governed.justification,
                    by: submitter,
                    policy: policy,
                    now: now)
                if case .held(let review) = disposition {
                    return .held(review)
                }
            } catch {
                Self.logger.error(
                    "Holding a governed override failed; rejecting rather than accepting unreviewed: \(String(describing: error), privacy: .public)")
                return .rejected(
                    reason: "review queue persistence failed: \(String(describing: error))")
            }
        }

        // Validated and ungoverned (or policy-free): enqueue.
        do {
            let receipt = try await queue.enqueue(request.operation, now: now)
            return .accepted(receipt, identity: identity)
        } catch {
            Self.logger.error(
                "Enqueue failed after validation: \(String(describing: error), privacy: .public)")
            return .rejected(reason: "write queue failed: \(String(describing: error))")
        }
    }

    /// The post-approval path: lands an operation whose review a distinct
    /// second identity has already approved in the ``ReviewQueue``.
    /// - Parameters:
    ///   - review: The approved review (approval is the precondition, not
    ///     re-checked against the policy — it already happened).
    ///   - operation: The held operation to apply.
    /// - Returns: The operation's queue receipt.
    /// - Throws: ``GovernedWriteError/reviewNotApproved(_:)`` when the
    ///   review is not approved; queue errors otherwise.
    public func applyApproved(
        _ review: PendingReview,
        operation: CorpusWriteOperation
    ) async throws -> QueuedReceipt {
        guard case .approved = review.state else {
            throw GovernedWriteError.reviewNotApproved(review.id)
        }
        return try await queue.enqueue(operation)
    }

    // MARK: - Validation

    /// The first schema violation in an operation, or `nil` when it is
    /// well-formed: the declared projectID must be non-empty and must match
    /// the artifact's own (work events carry no projectID of their own, so
    /// only the declared one is checked).
    private static func schemaViolation(in operation: CorpusWriteOperation) -> String? {
        switch operation {
        case .metadata(let metadata, _, let projectID):
            if projectID.isEmpty {
                return "projectID must be non-empty"
            }
            if metadata.projectID != projectID {
                return "projectID mismatch: operation declares \"\(projectID)\" but the metadata artifact carries \"\(metadata.projectID)\""
            }
        case .workEvent(_, let projectID):
            if projectID.isEmpty {
                return "projectID must be non-empty"
            }
        case .skip(let record, let projectID):
            if projectID.isEmpty {
                return "projectID must be non-empty"
            }
            if record.projectID != projectID {
                return "projectID mismatch: operation declares \"\(projectID)\" but the skip record carries \"\(record.projectID)\""
            }
        }
        return nil
    }

    /// The first override in the operation whose rule the policy governs,
    /// with its justification — `nil` when nothing needs a second reviewer.
    /// Only metadata operations carry overrides.
    private static func firstGovernedOverride(
        in operation: CorpusWriteOperation,
        policy: ReviewPolicy
    ) -> (ruleId: String, justification: String)? {
        guard case .metadata(let metadata, _, _) = operation else { return nil }
        return metadata.overrides
            .first { policy.requiresSecondReviewer(for: $0.diagnosticOverride.ruleId) }
            .map { ($0.diagnosticOverride.ruleId, $0.diagnosticOverride.justification) }
    }
}
