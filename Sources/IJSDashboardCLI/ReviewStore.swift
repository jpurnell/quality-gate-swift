import CorpusService
import Foundation
import QualityGateLogging
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

    /// Submits a governed judgment to the queue, from the TUI's synchronous event loop.
    ///
    /// Blocks the calling thread. Legal only off the cooperative pool — see ``bridge(_:)``
    /// for why, and prefer ``submit(corpusPath:ruleId:justification:by:)`` anywhere `await`
    /// is available.
    static func submitFromEventLoop(
        corpusPath: String, ruleId: String, justification: String, by identity: String
    ) -> String {
        bridge {
            await submit(
                corpusPath: corpusPath, ruleId: ruleId,
                justification: justification, by: identity)
        }
    }

    /// Submits a governed judgment to the queue. Returns the status line.
    static func submit(
        corpusPath: String, ruleId: String, justification: String, by identity: String
    ) async -> String {
        let queue = ReviewQueue(storePath: queuePath(corpusPath: corpusPath))
        let policy = policy(corpusPath: corpusPath)
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

    /// Applies an approve/reject through the queue, from the TUI's synchronous event loop.
    ///
    /// Blocks the calling thread. Legal only off the cooperative pool — see ``bridge(_:)``
    /// for why, and prefer ``apply(_:corpusPath:reviewer:)`` anywhere `await` is available.
    static func applyFromEventLoop(
        _ action: ReviewActionRequest, corpusPath: String, reviewer: String
    ) -> String {
        bridge { await apply(action, corpusPath: corpusPath, reviewer: reviewer) }
    }

    /// Applies an approve/reject through the queue (which enforces the
    /// distinct-second-identity rule). Returns the status line.
    static func apply(
        _ action: ReviewActionRequest, corpusPath: String, reviewer: String
    ) async -> String {
        let queue = ReviewQueue(storePath: queuePath(corpusPath: corpusPath))
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

    /// Bridges one async actor call onto the TUI's synchronous event loop.
    ///
    /// **Precondition: the caller must not be running on the cooperative thread pool.** This
    /// blocks its thread on a semaphore that only the spawned `Task` can signal, so if the
    /// caller already occupies a cooperative thread it is competing with the task it is
    /// waiting for. With the pool saturated the task never gets a thread, the wait burns its
    /// full deadline, and the result is a timeout notice rather than a deadlock — which is
    /// why it reads as flakiness instead of as a bug.
    ///
    /// That is exactly what happened: a *synchronous* test calling this from inside Swift
    /// Testing's task, in a 3,596-test parallel run, timed out on Linux while passing on
    /// macOS, whose wider pool nearly always wins the race. The TUI's own event loop is not
    /// a cooperative thread, so production is within the precondition — but nothing enforced
    /// it, and the only caller that broke it was a test.
    ///
    /// Prefer the `async` variants wherever `await` is available; these bridges exist for the
    /// event loop alone, which cannot `await` because it threads `inout DashboardState`.
    private static func bridge(_ body: @escaping @Sendable () async -> String) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<String>("")
        Task {
            let message = await body()
            result.withLock { $0 = message }
            semaphore.signal()
        }
        // A bare wait here hands the TUI's liveness to whatever `body` awaits. The deadline keeps
        // the event loop's fate in the event loop: the task is left running and its result
        // discarded, which is the right trade for a display refresh.
        if semaphore.wait(timeout: .now() + Self.bridgeDeadline) == .timedOut {
            logger.warning("Bridged actor call exceeded \(Self.bridgeDeadline, privacy: .public)s; showing a timeout notice.")
            return "Timed out after \(Int(Self.bridgeDeadline))s — still running in the background."
        }
        return result.withLock { $0 }
    }

    /// How long the synchronous event loop will wait on a bridged actor call.
    ///
    /// Shorter than the corpus-write deadline because this one blocks an interactive redraw: a
    /// display that stops repainting for thirty seconds reads as a crash.
    private static let bridgeDeadline: TimeInterval = 10
}
