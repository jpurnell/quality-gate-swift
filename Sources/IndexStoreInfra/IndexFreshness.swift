import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// How far an index store trails the sources it describes.
///
/// Compared by modification time rather than content hash: the question is not whether the
/// answer *would* differ, it is whether the index was built after the edit — which the file
/// system already knows. A hash would be more precise and would require reading every file to
/// learn it.
///
/// The timestamps are read from the **unit files**, not from any directory containing them.
/// A directory's mtime moves when its own entries are added or removed and not when a file
/// nested below it is rewritten, so a store directory can sit eight days behind the units
/// inside it — which is the state `.build/index-build/index-store` is in on this very
/// repository, and the reason `StoreLocator.needsRebuild` cannot answer this question.
public struct IndexFreshness: Sendable, Equatable {

    /// Modification time of the most recently edited source file considered.
    public let newestSource: Date
    /// Modification time of the most recently written index unit.
    public let newestIndexUnit: Date
    /// How many unit files the measurement examined.
    public let unitCount: Int

    /// Whether a source has been edited since the index was last written.
    public var isStale: Bool { newestSource > newestIndexUnit }

    /// How far the index trails the sources, in seconds. Negative when the index is newer.
    public var lag: TimeInterval { newestSource.timeIntervalSince(newestIndexUnit) }

    /// Creates a freshness measurement.
    ///
    /// - Parameters:
    ///   - newestSource: Modification time of the newest source file.
    ///   - newestIndexUnit: Modification time of the newest index unit.
    ///   - unitCount: How many unit files were examined.
    public init(newestSource: Date, newestIndexUnit: Date, unitCount: Int) {
        self.newestSource = newestSource
        self.newestIndexUnit = newestIndexUnit
        self.unitCount = unitCount
    }
}

/// The outcome of attempting to measure index freshness.
///
/// Three cases rather than an optional `IndexFreshness`, because "could not measure" and
/// "measured, and it is current" are different answers and collapsing them reinstates exactly
/// the assertion this type exists to remove: `StoreLocator.locate` returned
/// `LocatedStore(url:, isStale: false)` on the SwiftPM path without ever measuring, and a
/// checker cannot tell an unexamined index from a fresh one if the API cannot either.
public enum IndexFreshnessMeasurement: Sendable, Equatable {
    /// The index and the sources were both readable and compared.
    case measured(IndexFreshness)
    /// No unit files were found — the store is absent, empty, or not laid out as a v5 store.
    case noIndexUnits
    /// No Swift sources were found to compare against.
    case noSources
}

extension IndexFreshness {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "IndexFreshness")

    /// Measures whether the index store at `storeURL` was written after the sources under
    /// `sourceRoots`.
    ///
    /// - Parameters:
    ///   - storeURL: The index store directory, e.g. `.build/index-build/index-store` or
    ///     `.build/out`. Units are read from `v5/units` beneath it.
    ///   - sourceRoots: Directories to walk for `.swift` files. Callers should pass the
    ///     project root rather than a list of target directories: which directories hold
    ///     targets is configurable, and a root omitted here fails in the *fresh* direction —
    ///     silently. A root that does not exist contributes nothing.
    ///   - excludePatterns: Exclusion patterns, applied with the same substring semantics
    ///     `SourceWalker` uses, so an excluded file cannot make the index look stale.
    /// - Returns: The comparison, or which half of it could not be read.
    public static func measure(
        storeURL: URL,
        sourceRoots: [URL],
        excludePatterns: [String] = []
    ) -> IndexFreshnessMeasurement {
        guard let units = newestUnit(inStoreAt: storeURL) else { return .noIndexUnits }
        guard let newestSource = newestSourceMtime(
            under: sourceRoots,
            excludePatterns: excludePatterns
        ) else { return .noSources }

        return .measured(IndexFreshness(
            newestSource: newestSource,
            newestIndexUnit: units.newest,
            unitCount: units.count
        ))
    }

    /// Newest mtime and file count among the unit records of a v5 index store.
    ///
    /// Returns `nil` when the units directory is missing or holds no files — an index that
    /// cannot be dated is not an index that is current.
    static func newestUnit(inStoreAt storeURL: URL) -> (newest: Date, count: Int)? {
        let units = StoreLocator.unitsDirectory(in: storeURL)
        let fm = FileManager.default
        // silent: an absent or unreadable units directory is the expected no-store case, reported to the caller as `.noIndexUnits` rather than as an error.
        guard let entries = try? fm.contentsOfDirectory(
            at: units,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), !entries.isEmpty else { return nil }

        var newest: Date?
        var count = 0
        for entry in entries {
            guard let mtime = modificationDate(of: entry) else { continue }
            count += 1
            if newest.map({ mtime > $0 }) ?? true { newest = mtime }
        }
        guard let newest, count > 0 else { return nil }
        return (newest, count)
    }

    /// Newest mtime among the `.swift` files under `roots`, honoring `excludePatterns`.
    static func newestSourceMtime(under roots: [URL], excludePatterns: [String]) -> Date? {
        var newest: Date?
        for root in roots {
            for path in SourceWalker.swiftFiles(under: root, excludePatterns: excludePatterns) {
                guard let mtime = modificationDate(of: URL(fileURLWithPath: path)) else { continue }
                if newest.map({ mtime > $0 }) ?? true { newest = mtime }
            }
        }
        return newest
    }

    private static func modificationDate(of url: URL) -> Date? {
        do {
            // SAFETY: CLI tool reads local file attributes
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return attrs[.modificationDate] as? Date
        } catch {
            logger.warning("Could not read modification date for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Diagnostics

extension IndexFreshness {

    /// A timestamp format stable across locales, for messages a reader compares against a
    /// file listing.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// The barrier a checker emits **instead of** its findings when the index is stale.
    ///
    /// Not a finding about the code: a statement that the question could not be answered.
    /// It replaces the findings rather than accompanying them, because a reader shown both
    /// acts on the findings and reads the barrier as noise — which is how three plausible
    /// dead symbols nearly got deleted from a library on a stale index's authority.
    ///
    /// - Parameters:
    ///   - checkerId: The checker's id, used to scope the rule identifier.
    ///   - subject: What the checker would have determined, as a noun phrase — e.g.
    ///     `"reachability"`. Named rather than derived from `checkerId` so the sentence reads
    ///     as a statement about the question, not about the tool.
    ///   - storeURL: The store that was found to be stale, named so the reader can date it.
    /// - Returns: An error-severity diagnostic carrying both timestamps and the hint.
    public func staleBarrier(checkerId: String, subject: String, storeURL: URL) -> Diagnostic {
        Diagnostic(
            severity: .error,
            message: """
                The index is older than the sources it would be read against, so \
                \(subject) could not be determined. Newest source \
                \(Self.stamp(newestSource)); newest index unit \(Self.stamp(newestIndexUnit)) \
                (\(unitCount) units at \(storeURL.path)).
                """,
            ruleId: "\(checkerId).index.stale-barrier",
            suggestedFix: """
                Rebuild the index — `swift build` — and re-run. `--no-cache` re-runs the \
                checker but does not rebuild the index; they are different artefacts, so the \
                flag reached for when a result looks stale is the one that cannot help here.
                """
        )
    }

    /// The provenance note a checker emits on every index-backed run, including a clean one.
    ///
    /// A reader should be able to tell a fresh analysis from a stale one without knowing that
    /// `.build/index-build` exists — the same reason the gate prints a coverage line whether
    /// or not it found anything.
    ///
    /// - Parameter checkerId: The checker's id, used to scope the rule identifier.
    /// - Returns: A note-severity diagnostic stating the index's age and size.
    public func coverageNote(checkerId: String) -> Diagnostic {
        let relation = lag <= 0
            ? "\(Self.duration(-lag)) newer than the newest source"
            : "\(Self.duration(lag)) older than the newest source"
        return Diagnostic(
            severity: .note,
            message: "Index built \(Self.stamp(newestIndexUnit)), \(relation) · \(unitCount) units.",
            ruleId: "\(checkerId).index.age"
        )
    }

    /// Renders a non-negative duration in the largest unit that keeps it readable.
    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m" }
        if total < 86_400 { return "\(total / 3_600)h" }
        return "\(total / 86_400)d"
    }
}
