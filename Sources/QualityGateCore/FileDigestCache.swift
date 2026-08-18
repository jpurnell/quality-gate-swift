import Foundation
import Synchronization

/// A per-run, thread-safe memo of file-content digests, shared across checkers.
///
/// Every cache-participating checker fingerprints its declared input files, and the
/// index-backed checkers all declare the same whole-source set — so without sharing, a
/// warm run hashes the same ~660 files once per checker (~27,000 reads). One instance
/// of this cache per `CheckerRunner` run collapses that to one hash per file.
///
/// Digests are memoized at first use for the remainder of the run (snapshot semantics).
/// That is safe because declared inputs are sources, manifests, `.gitignore`, and
/// `.docc` files — nothing the gate itself mutates mid-run; `SourceWalker` skips
/// `.build` and the records directory. If a checker ever declares a gate-mutated path
/// as a cache input, this snapshot assumption must be revisited (see
/// `project/plans/proposals/SharedFileDigestMap.md`).
///
/// The map deliberately dies with the process: cross-run memoization would reintroduce
/// exactly the staleness class the per-run scope avoids.
public final class FileDigestCache: Sendable {

    private let store = Mutex<[String: String]>([:])

    /// Creates an empty per-run digest cache.
    public init() {}

    /// The content digest for `path`, computed on first use and memoized thereafter.
    ///
    /// Hashing happens *outside* the lock so concurrent checkers never serialize on
    /// file I/O; two racing first reads of the same unchanged file compute the same
    /// value, and either store is correct.
    ///
    /// - Parameter path: Absolute path of the input file.
    /// - Returns: SHA-256 hex digest of the file's contents, or the same
    ///   missing-file sentinel `CheckerFingerprint.fileDigest` returns.
    public func digest(for path: String) -> String {
        if let cached = store.withLock({ $0[path] }) {
            return cached
        }
        let computed = CheckerFingerprint.fileDigest(path)
        store.withLock { $0[path] = computed }
        return computed
    }
}
