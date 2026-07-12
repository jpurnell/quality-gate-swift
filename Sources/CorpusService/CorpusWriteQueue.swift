import CorpusKit
import Foundation

/// One validated write bound for the corpus (Phase 3b §1).
///
/// The three artifact families corpusd accepts today. Each case carries the
/// project the write targets; ``GovernedWriteHandler`` validates that the
/// declared project matches the artifact's own before the operation reaches
/// the queue.
public enum CorpusWriteOperation: Sendable, Codable {
    /// A gate run's metadata and any judgment calibrations.
    case metadata(CheckResultMetadata, calibrations: [JudgmentCalibration], projectID: String)
    /// A work event upserted into the project's work log.
    case workEvent(WorkEvent, projectID: String)
    /// A gate skip with its accountability reference.
    case skip(SkipRecord, projectID: String)
}

/// Proof that an operation entered the ordered write queue.
public struct QueuedReceipt: Sendable, Codable, Equatable {
    /// The operation's position in the queue's strict total order (1-based).
    public let sequence: Int
    /// When the operation was enqueued.
    public let timestamp: Date

    /// Creates a receipt.
    /// - Parameters:
    ///   - sequence: The operation's 1-based position in the queue order.
    ///   - timestamp: When the operation was enqueued.
    public init(sequence: Int, timestamp: Date) {
        self.sequence = sequence
        self.timestamp = timestamp
    }
}

/// The outcome of a ``CorpusWriteQueue/flush()``.
public struct FlushResult: Sendable, Equatable {
    /// How many operations the flush covered (0 when nothing was dirty).
    public let operationCount: Int
    /// The batch commit's SHA, or `nil` when nothing was dirty.
    public let commitSHA: String?

    /// Creates a flush result.
    /// - Parameters:
    ///   - operationCount: How many operations the flush covered.
    ///   - commitSHA: The batch commit's SHA, or `nil` when nothing was dirty.
    public init(operationCount: Int, commitSHA: String?) {
        self.operationCount = operationCount
        self.commitSHA = commitSHA
    }
}

/// Typed failures from ``CorpusWriteQueue`` git operations.
public enum CorpusWriteQueueError: Error, Sendable, Equatable {
    /// A git invocation exited nonzero; carries the combined output
    /// (stderr included) for diagnosis.
    case gitCommandFailed(arguments: [String], status: Int32, output: String)
    /// The remote rejected the batch push. corpusd is the corpus's only
    /// writer by construction, so a rejection means the deployment invariant
    /// broke — the error surfaces with git's output; it is never auto-merged.
    case pushRejected(output: String)
}

/// The single-writer heart of corpusd (Phase 3b §1).
///
/// Every validated write appends to an ordered in-memory queue and is
/// applied to the service's working clone immediately (the artifact is on
/// disk before ``enqueue(_:now:)`` returns). ``flush()`` turns everything
/// applied since the last flush into exactly one commit — batched git
/// commits by a single writer, so push races and merge noise end by
/// construction. There is deliberately no pull/merge path: corpusd is the
/// only writer of its clone, and a rejected push surfaces as a typed error
/// instead of being merged away.
public actor CorpusWriteQueue {

    /// The service's checkout of the corpus repository — the corpus base
    /// path artifacts are applied under, and the git worktree flushes
    /// commit in.
    public let workingClone: String

    /// The suggested batching cadence for the owning daemon's periodic
    /// ``flush()`` timer. The queue itself never flushes on its own —
    /// timing policy belongs to the service shell, not the trust core.
    public let batchWindow: Duration

    private let transport: any CorpusTransport
    private var nextSequence = 1
    private var appliedSinceFlush: [Int] = []
    private var batchNumber = 0

    /// Creates a write queue over the service's working clone.
    /// - Parameters:
    ///   - workingClone: Absolute path of the service's corpus checkout.
    ///   - transport: How artifacts are applied to the clone; defaults to
    ///     the direct filesystem transport.
    ///   - batchWindow: Suggested flush cadence for the owning daemon.
    public init(
        workingClone: String,
        transport: any CorpusTransport = DirectCorpusTransport(),
        batchWindow: Duration = .seconds(2)
    ) {
        self.workingClone = workingClone
        self.transport = transport
        self.batchWindow = batchWindow
    }

    /// Appends an operation to the ordered queue and applies it to the
    /// working clone immediately.
    ///
    /// Sequence numbers are assigned on arrival, before any suspension, so
    /// concurrent callers receive strictly ordered receipts. The artifact is
    /// on disk (via the transport) before this method returns, and the
    /// batch is marked dirty for the next ``flush()``.
    /// - Parameters:
    ///   - operation: The validated write to apply.
    ///   - now: The enqueue timestamp recorded on the receipt.
    /// - Returns: The operation's receipt (sequence number + timestamp).
    /// - Throws: Transport errors when the artifact cannot be applied; the
    ///   consumed sequence number is not reused.
    public func enqueue(
        _ operation: CorpusWriteOperation,
        now: Date = Date()
    ) async throws -> QueuedReceipt {
        let sequence = nextSequence
        nextSequence += 1
        try await apply(operation)
        appliedSinceFlush.append(sequence)
        return QueuedReceipt(sequence: sequence, timestamp: now)
    }

    /// Commits everything applied since the last flush as one batch commit,
    /// then pushes when an `origin` remote exists.
    ///
    /// The commit message is `corpusd: batch <n> ops <first-seq>..<last-seq>`.
    /// A clone without an `origin` remote simply keeps the commit local —
    /// solo deployments need no remote. There is no pull/merge: a rejected
    /// push throws ``CorpusWriteQueueError/pushRejected(output:)`` (the
    /// local batch commit remains intact for the operator to reconcile).
    /// - Returns: The ops count and commit SHA — `nil` SHA when nothing was
    ///   dirty (no commit is created).
    /// - Throws: ``CorpusWriteQueueError`` when a git step fails.
    public func flush() async throws -> FlushResult {
        guard !appliedSinceFlush.isEmpty else {
            return FlushResult(operationCount: 0, commitSHA: nil)
        }
        guard let firstSequence = appliedSinceFlush.min(),
              let lastSequence = appliedSinceFlush.max() else {
            return FlushResult(operationCount: 0, commitSHA: nil)
        }
        let operationCount = appliedSinceFlush.count

        try runGit(["add", "-A"])
        guard try hasStagedChanges() else {
            // Idempotent rewrites can leave the tree unchanged; the batch is
            // acknowledged without a commit.
            appliedSinceFlush.removeAll()
            return FlushResult(operationCount: operationCount, commitSHA: nil)
        }

        batchNumber += 1
        let message = "corpusd: batch \(batchNumber) ops \(firstSequence)..\(lastSequence)"
        try runGit([
            "-c", "user.name=corpusd",
            "-c", "user.email=corpusd@quality-gate.invalid",
            "commit", "-qm", message,
        ])
        appliedSinceFlush.removeAll()
        let commitSHA = try runGit(["rev-parse", "HEAD"])

        if hasOriginRemote() {
            do {
                try runGit(["push", "-q", "origin", "HEAD"])
            } catch CorpusWriteQueueError.gitCommandFailed(_, _, let output) {
                throw CorpusWriteQueueError.pushRejected(output: output)
            }
        }
        return FlushResult(operationCount: operationCount, commitSHA: commitSHA)
    }

    // MARK: - Applying operations

    /// Applies one operation to the working clone through the transport.
    private func apply(_ operation: CorpusWriteOperation) async throws {
        switch operation {
        case .metadata(let metadata, let calibrations, let projectID):
            try await transport.write(
                metadata: metadata,
                calibrations: calibrations,
                to: CorpusPath(basePath: workingClone, projectID: projectID))
        case .workEvent(let event, let projectID):
            try await transport.writeWorkEvent(
                event, to: CorpusPath(basePath: workingClone, projectID: projectID))
        case .skip(let record, let projectID):
            try await transport.writeSkip(
                record, to: CorpusPath(basePath: workingClone, projectID: projectID))
        }
    }

    // MARK: - Git plumbing

    /// Whether the clone has a remote named `origin`.
    private func hasOriginRemote() -> Bool {
        // silent: a failed spawn means git is unusable here; "no remote" keeps flush local-only, and runGit surfaces real git failures.
        guard let result = try? executeGit(["remote", "get-url", "origin"]) else {
            return false
        }
        return result.status == 0
    }

    /// Whether the index holds anything to commit.
    /// (`git diff --cached --quiet` exits 1 when differences exist.)
    private func hasStagedChanges() throws -> Bool {
        let result = try executeGit(["diff", "--cached", "--quiet"])
        return result.status == 1
    }

    /// Runs git in the working clone, throwing a typed error carrying the
    /// combined output on a nonzero exit.
    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        let result = try executeGit(arguments)
        guard result.status == 0 else {
            throw CorpusWriteQueueError.gitCommandFailed(
                arguments: arguments, status: result.status, output: result.output)
        }
        return result.output
    }

    /// Spawns git with a scrubbed environment and returns its exit status
    /// and trimmed combined output.
    ///
    /// The output pipe is drained before `waitUntilExit()` — a full ~64 KB
    /// pipe buffer would deadlock a chatty invocation.
    private func executeGit(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingClone)
        process.environment = Self.scrubbed(environment: ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain the pipe before waiting to avoid the pipe-buffer deadlock.
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    /// The environment for spawned git: hook-leak variables removed
    /// (GIT_INDEX_FILE/GIT_DIR/GIT_WORK_TREE point at the *hooked* repo when
    /// running inside a commit hook — the Phase 1 war story), credential
    /// transport (GIT_SSH_COMMAND, deploy keys) preserved.
    static func scrubbed(environment: [String: String]) -> [String: String] {
        var scrubbed = environment
        for leaked in ["GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_PREFIX", "GIT_COMMON_DIR"] {
            scrubbed.removeValue(forKey: leaked)
        }
        return scrubbed
    }
}
