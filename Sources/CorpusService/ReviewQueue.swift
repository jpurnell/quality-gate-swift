import Foundation
#if canImport(os)
import os
#endif

/// The outcome of submitting a governed override (Phase 3b §3).
public enum ReviewDisposition: Sendable, Equatable {
    /// Solo passthrough — no policy, or the rule is self-acknowledgeable.
    /// Today's behavior exactly.
    case accepted
    /// The rule requires a distinct second reviewer; the override is
    /// recorded as pending review, visible, and never lost.
    case held(PendingReview)
}

/// Typed failures from ``ReviewQueue`` operations.
public enum ReviewQueueError: Error, Equatable, Sendable {
    /// No review exists with this id.
    case unknownReview(String)
    /// The review has already been approved or rejected.
    case notPending(String)
    /// The submitter tried to review their own submission — a distinct
    /// second verified identity is the whole point.
    case secondIdentityRequired(String)
}

/// The governed-escape-hatch state machine (Phase 3b §3).
///
/// A governed override submitted without a distinct second verified
/// identity is held — recorded as pending, visible on the dashboard —
/// until a second identity approves or rejects it. Both actions are
/// artifacts. Persistence mirrors ``TokenStore``: deterministic pretty
/// JSON, atomic writes, missing file = empty queue.
public actor ReviewQueue {

    /// The on-disk shape: a schema version and reviews in insertion order.
    private struct StoreFile: Sendable, Codable, Equatable {
        var version: Int
        var reviews: [PendingReview]
    }

    private static let schemaVersion = 1

    private static let logger = Logger(subsystem: "com.quality-gate", category: "ReviewQueue")

    private let storePath: String
    private var reviews: [PendingReview]

    /// Opens (or lazily creates) the review queue at `storePath`.
    ///
    /// A missing file is an empty queue. An unreadable file is logged and
    /// treated as empty rather than crashing the daemon; the broken file is
    /// only overwritten by the next successful mutation.
    /// - Parameter storePath: Absolute path of the JSON store file.
    public init(storePath: String) {
        self.storePath = storePath
        do {
            self.reviews = try JSONStoreIO.load(StoreFile.self, atPath: storePath)?.reviews ?? []
        } catch {
            Self.logger.error(
                "Review queue at \(storePath, privacy: .public) is unreadable; starting empty: \(String(describing: error), privacy: .public)")
            self.reviews = []
        }
    }

    /// Submits an override or calibration against `ruleId`.
    ///
    /// With no policy, or when the rule does not require a second
    /// reviewer, the submission is accepted — solo passthrough, today's
    /// behavior exactly. A governed rule is held as a ``PendingReview``.
    /// - Parameters:
    ///   - ruleId: The rule the override targets.
    ///   - justification: The submitter's stated justification.
    ///   - by: The submitter's verified identity name.
    ///   - policy: The resolved review policy, or `nil` when none exists.
    ///   - now: The submission timestamp.
    /// - Returns: ``ReviewDisposition/accepted`` or
    ///   ``ReviewDisposition/held(_:)`` with the recorded review.
    /// - Throws: Persistence errors when recording a held review.
    public func submit(
        ruleId: String,
        justification: String,
        by identity: String,
        policy: ReviewPolicy?,
        now: Date
    ) throws -> ReviewDisposition {
        guard let policy, policy.requiresSecondReviewer(for: ruleId) else {
            return .accepted
        }
        let review = PendingReview(
            id: UUID().uuidString,
            ruleId: ruleId,
            justification: justification,
            submittedBy: identity,
            submittedAt: now,
            state: .pending)
        reviews.append(review)
        try persist()
        return .held(review)
    }

    /// Approves a pending review — an artifact, recorded and persisted.
    /// - Parameters:
    ///   - id: The review's identifier.
    ///   - by: The approving verified identity; must differ from the
    ///     submitter.
    ///   - now: The approval timestamp.
    /// - Returns: The review in its approved state.
    /// - Throws: ``ReviewQueueError/unknownReview(_:)``,
    ///   ``ReviewQueueError/notPending(_:)``, or
    ///   ``ReviewQueueError/secondIdentityRequired(_:)`` when the submitter
    ///   reviews their own submission; persistence errors otherwise.
    public func approve(id: String, by identity: String, now: Date) throws -> PendingReview {
        try transition(id: id, by: identity) { .approved(by: identity, at: now) }
    }

    /// Rejects a pending review, recording the reviewer's reason.
    /// - Parameters:
    ///   - id: The review's identifier.
    ///   - by: The rejecting verified identity; must differ from the
    ///     submitter.
    ///   - reason: Why the override was rejected — part of the artifact.
    ///   - now: The rejection timestamp.
    /// - Returns: The review in its rejected state.
    /// - Throws: ``ReviewQueueError/unknownReview(_:)``,
    ///   ``ReviewQueueError/notPending(_:)``, or
    ///   ``ReviewQueueError/secondIdentityRequired(_:)`` when the submitter
    ///   reviews their own submission; persistence errors otherwise.
    public func reject(
        id: String,
        by identity: String,
        reason: String,
        now: Date
    ) throws -> PendingReview {
        try transition(id: id, by: identity) { .rejected(by: identity, at: now, reason: reason) }
    }

    /// The review with the given id, in whatever state — the resolve
    /// loop's lookup.
    /// - Parameter id: The review id.
    public func review(id: String) -> PendingReview? {
        reviews.first { $0.id == id }
    }

    /// The reviews still awaiting a second identity, oldest first.
    public func pending() -> [PendingReview] {
        reviews
            .filter { $0.state == .pending }
            .sorted { ($0.submittedAt, $0.id) < ($1.submittedAt, $1.id) }
    }

    // MARK: - Internals

    /// Applies a reviewed-state transition under the shared guards:
    /// the review must exist, must be pending, and the reviewer must be a
    /// distinct identity from the submitter.
    private func transition(
        id: String,
        by identity: String,
        to newState: () -> PendingReview.State
    ) throws -> PendingReview {
        guard let index = reviews.firstIndex(where: { $0.id == id }) else {
            throw ReviewQueueError.unknownReview(id)
        }
        guard reviews[index].state == .pending else {
            throw ReviewQueueError.notPending(id)
        }
        guard reviews[index].submittedBy != identity else {
            throw ReviewQueueError.secondIdentityRequired(id)
        }
        reviews[index].state = newState()
        try persist()
        return reviews[index]
    }

    /// Atomically writes the current reviews to the store file.
    private func persist() throws {
        try JSONStoreIO.save(
            StoreFile(version: Self.schemaVersion, reviews: reviews),
            toPath: storePath)
    }
}
