import Foundation
import CorpusKit
import IJSDashboardCore
import QualityGateTypes

/// What the terminal dashboard holds of the corpus between refreshes.
///
/// It used to be `CorpusReader.loadAll()`: every run of every project, findings included,
/// held for the life of the session and replaced wholesale every thirty seconds. Against a
/// 3 GB corpus that is the same shape that put the native dashboard at 11.9 GB.
///
/// This holds each project's history *without* diagnostics — which is all the summaries, the
/// health timeline and the trend chart read — and the findings only for its present state:
/// each checker's latest standard-mode result. A refresh asks each project for its
/// ``HistorySignature`` and re-reads only the ones that differ.
public struct CorpusHistories: Sendable {
    /// Each project's runs, ascending by timestamp, with every result's diagnostics empty.
    public private(set) var runs: [String: [TimestampedRun]] = [:]
    /// Each project's latest standard-mode result per checker, diagnostics included.
    public private(set) var latestResults: [String: [CheckResult]] = [:]
    /// Each project's history signature when it was last read.
    private var signatures: [String: HistorySignature] = [:]

    /// Creates an empty set of histories; ``refresh(from:)`` fills it.
    public init() {}

    /// Brings the held histories up to date with the corpus.
    ///
    /// A project whose signature is unchanged is not read. One that is new or changed is read
    /// through `CorpusReader.loadHistory(for:)`; one that has left the corpus is dropped.
    ///
    /// - Parameter reader: The corpus to read.
    /// - Returns: The projects that were read or dropped — empty when nothing changed.
    /// - Throws: When the corpus cannot be listed or a changed project cannot be read. The
    ///   held histories are left as they were for every project not yet reached.
    @discardableResult
    public mutating func refresh(from reader: CorpusReader) throws -> Set<String> {
        var changed: Set<String> = []
        let projects = Set(try reader.discoverProjects())

        for project in projects.sorted() {
            let signature = try reader.historySignature(for: project)
            guard signatures[project] != signature else { continue }
            let history = try reader.loadHistory(for: project)
            runs[project] = history.runs
            latestResults[project] = history.latestStandardResults
            signatures[project] = signature
            changed.insert(project)
        }

        for project in Set(signatures.keys).subtracting(projects) {
            runs[project] = nil
            latestResults[project] = nil
            signatures[project] = nil
            changed.insert(project)
        }
        return changed
    }
}
