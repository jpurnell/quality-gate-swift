import CorpusService
import Foundation
#if canImport(os)
import os
#endif
import Synchronization
import Yams

/// The dashboard's synchronous façade over the shared review artifacts
/// (Phase 3b §3): the org policy and the review queue, both living in the
/// corpus root so git distributes them today and corpusd serves them later.
///
/// - `<corpus>/review-policy.yml` — the org's governed-rule globs.
/// - `<corpus>/pending-reviews.json` — the ReviewQueue's store.
///
/// Reads are direct file decodes (the queue actor is the only writer);
/// mutations go through the actor, bridged onto the TUI's synchronous
/// event loop.
enum ReviewStore {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "ReviewStore")

    /// The review-policy path inside a corpus.
    static func policyPath(corpusPath: String) -> String {
        (corpusPath as NSString).appendingPathComponent("review-policy.yml")
    }

    /// The review-queue store path inside a corpus.
    static func queuePath(corpusPath: String) -> String {
        (corpusPath as NSString).appendingPathComponent("pending-reviews.json")
    }

    /// Loads the org review policy; nil when the corpus declares none
    /// (solo mode — no governance, today's behavior exactly).
    static func policy(corpusPath: String) -> ReviewPolicy? {
        let path = policyPath(corpusPath: corpusPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil } // SAFETY: read-only existence check
        do {
            let yaml = try String(contentsOfFile: path, encoding: .utf8)
            guard let object = try Yams.load(yaml: yaml) else { return nil }
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(ReviewPolicy.self, from: data)
        } catch {
            logger.warning("Unreadable review policy at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Every review on record, any state. Direct decode of the queue's
    /// documented store format.
    static func all(corpusPath: String) -> [PendingReview] {
        let path = queuePath(corpusPath: corpusPath)
        guard FileManager.default.fileExists(atPath: path) else { return [] } // SAFETY: read-only existence check
        struct StoreFile: Decodable {
            let reviews: [PendingReview]
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(StoreFile.self, from: Data(contentsOf: URL(fileURLWithPath: path))).reviews
        } catch {
            logger.warning("Unreadable review store at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// The reviews still awaiting a decision, oldest first.
    static func pending(corpusPath: String) -> [PendingReview] {
        all(corpusPath: corpusPath)
            .filter { $0.state == .pending }
            .sorted { $0.submittedAt < $1.submittedAt }
    }

    /// Submits a governed judgment to the queue. Returns the status line.
    static func submit(
        corpusPath: String, ruleId: String, justification: String, by identity: String
    ) -> String {
        let queue = ReviewQueue(storePath: queuePath(corpusPath: corpusPath))
        let policy = policy(corpusPath: corpusPath)
        return bridge { () -> String in
            do {
                let disposition = try await queue.submit(
                    ruleId: ruleId, justification: justification,
                    by: identity, policy: policy, now: Date())
                switch disposition {
                case .accepted:
                    return "Accepted without review — the rule is not governed."
                case .held:
                    return "Held for review — a second identity approves in the Reviews view (v)."
                }
            } catch {
                Self.logger.warning("Review submit failed: \(error.localizedDescription, privacy: .public)")
                return "Review submit failed: \(error.localizedDescription)"
            }
        }
    }

    /// Applies an approve/reject through the queue (which enforces the
    /// distinct-second-identity rule). Returns the status line.
    static func apply(
        _ action: ReviewActionRequest, corpusPath: String, reviewer: String
    ) -> String {
        let queue = ReviewQueue(storePath: queuePath(corpusPath: corpusPath))
        return bridge { () -> String in
            do {
                switch action.action {
                case .approve:
                    let review = try await queue.approve(id: action.reviewID, by: reviewer, now: Date())
                    return "Approved \(review.ruleId) — the submitter's next acknowledge writes the marker."
                case .reject:
                    let review = try await queue.reject(
                        id: action.reviewID, by: reviewer,
                        reason: action.reason ?? "", now: Date())
                    return "Rejected \(review.ruleId) — recorded with your reason."
                }
            } catch let error as ReviewQueueError {
                Self.logger.warning("Review action refused: \(String(describing: error), privacy: .public)")
                if case .secondIdentityRequired = error {
                    return "A DISTINCT second identity must decide — you submitted this judgment."
                }
                return "Review action failed: \(error)"
            } catch {
                Self.logger.warning("Review action failed: \(error.localizedDescription, privacy: .public)")
                return "Review action failed: \(error.localizedDescription)"
            }
        }
    }

    /// Bridges one async actor call onto the TUI's synchronous event loop.
    private static func bridge(_ body: @escaping @Sendable () async -> String) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<String>("")
        Task {
            let message = await body()
            result.withLock { $0 = message }
            semaphore.signal()
        }
        semaphore.wait()
        return result.withLock { $0 }
    }
}
