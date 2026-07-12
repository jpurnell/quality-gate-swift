import Foundation
#if canImport(os)
import os
#endif

/// The held-operation spool (Phase 3b §1/§3): a governed write that goes
/// `.held` persists here, byte-faithful, until its review is decided —
/// approval lands the original artifact, rejection discards it.
///
/// Without this store, "held, never lost" would be a promise about the
/// review record only; the artifact itself would vanish between hold and
/// approval. One JSON file per review id, deterministic encoding, atomic
/// writes — the same audit-friendly posture as every other corpus store.
public actor HeldOperationStore {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "HeldOperationStore")

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a spool rooted at a directory (created on first hold).
    /// - Parameter directory: Where held operations live, one file per review.
    public init(directory: URL) {
        self.directory = directory
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Persists a held operation under its review id.
    /// - Parameters:
    ///   - operation: The operation exactly as it arrived.
    ///   - reviewID: The ``PendingReview`` id it is held behind.
    public func hold(_ operation: CorpusWriteOperation, forReview reviewID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(operation).write(to: fileURL(for: reviewID), options: .atomic)
    }

    /// Loads the operation held behind a review, or `nil` when none is.
    /// - Parameter reviewID: The review id to look up.
    public func operation(forReview reviewID: String) -> CorpusWriteOperation? {
        let url = fileURL(for: reviewID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil } // SAFETY: read-only existence check
        do {
            return try decoder.decode(CorpusWriteOperation.self, from: Data(contentsOf: url))
        } catch {
            Self.logger.error("Corrupt held operation for review \(reviewID, privacy: .public): \(error.localizedDescription, privacy: .public) — leaving in place")
            return nil
        }
    }

    /// Removes a decided review's held operation. Removing an absent entry
    /// is a no-op, so resolve loops are idempotent.
    /// - Parameter reviewID: The review id whose operation is consumed.
    public func discard(reviewID: String) throws {
        let url = fileURL(for: reviewID)
        guard FileManager.default.fileExists(atPath: url.path) else { return } // SAFETY: read-only existence check
        try FileManager.default.removeItem(at: url)
    }

    /// The spool file for a review id (sanitized — review ids are UUIDs, but
    /// never trust a path component).
    private func fileURL(for reviewID: String) -> URL {
        let safe = reviewID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }
}
