import Foundation
import QualityGateCore

/// What one unit file in an index store says about itself.
///
/// A unit is the record of one compilation of one source file. Its *name* is derived from its
/// output path — `QRCodeError.o-2EHOFO6YVTDTW` is the basename and a hash of
/// `/Ignite.build/Debug/IgniteCLI-…-testable-t.build/Objects-normal/arm64/QRCodeError.o` — so
/// the same source compiled for two build variants yields two units with different names, and
/// neither build removes the other's.
public struct IndexUnitRecord: Sendable, Equatable {
    /// The unit's file name under `v5/units`.
    public let name: String
    /// When the unit was written.
    public let modified: Date
    /// The source file whose compilation produced the unit; empty for a module or PCH unit.
    public let mainFile: String
    /// The build's identifier for this compilation — its output path. Two units for one source
    /// differ here, and this is the handle IndexStoreDB accepts for declaring a unit visible.
    public let outputFile: String
    /// The Swift module the source was compiled into.
    public let moduleName: String
    /// The target triple the source was compiled for.
    public let target: String

    /// Whether the unit was produced by compiling a source file.
    public var hasMainFile: Bool { !mainFile.isEmpty }

    /// Creates a unit record.
    ///
    /// - Parameters:
    ///   - name: The unit's file name.
    ///   - modified: When the unit was written.
    ///   - mainFile: The source file compiled, or empty.
    ///   - outputFile: The compilation's output path.
    ///   - moduleName: The module compiled into.
    ///   - target: The target triple.
    public init(
        name: String, modified: Date, mainFile: String,
        outputFile: String, moduleName: String, target: String
    ) {
        self.name = name
        self.modified = modified
        self.mainFile = mainFile
        self.outputFile = outputFile
        self.moduleName = moduleName
        self.target = target
    }
}

/// Whether a unit describes its source as the source is now.
public enum IndexUnitVerdict: Sendable, Equatable {
    /// Written after the source was last edited, and the latest unit for its compilation.
    case current
    /// The source was edited after the unit was written. The unit describes code that has
    /// changed: its lines are wrong and it may name symbols that no longer exist.
    case stale
    /// A newer unit exists for the same source, module and platform. This one is a build
    /// variant nothing writes any more.
    case superseded
    /// The source file no longer exists.
    case orphaned
}

/// Which units of a store may be read, and how many may not.
public struct IndexUnitCensus: Sendable, Equatable {
    /// The output paths of the units that describe current source — the set a session declares
    /// visible to IndexStoreDB.
    public let currentOutputPaths: [String]
    /// How many units compiled from a source file were examined.
    public let examined: Int
    /// How many were ignored because their source was edited after they were written.
    public let stale: Int
    /// How many were ignored because a newer unit for the same compilation exists.
    public let superseded: Int
    /// How many were ignored because their source file is gone.
    public let orphaned: Int
    /// Sources that still exist and have units, none of them current.
    ///
    /// These are holes, not clutter. Ignoring a stale unit beside a fresh one loses nothing;
    /// ignoring the *only* unit a file has removes every reference that file makes, and whatever
    /// it alone calls then reads as unreachable.
    public let sourcesWithoutCurrentUnit: [String]

    /// How many units were not read, for any reason.
    public var ignored: Int { stale + superseded + orphaned }

    /// Creates a census.
    ///
    /// - Parameters:
    ///   - currentOutputPaths: Output paths of the units that may be read.
    ///   - examined: Units with a main file that were judged.
    ///   - stale: Units older than their source.
    ///   - superseded: Units with a newer sibling.
    ///   - orphaned: Units whose source is gone.
    ///   - sourcesWithoutCurrentUnit: Existing sources left with no current unit.
    public init(
        currentOutputPaths: [String], examined: Int, stale: Int, superseded: Int, orphaned: Int,
        sourcesWithoutCurrentUnit: [String]
    ) {
        self.currentOutputPaths = currentOutputPaths
        self.examined = examined
        self.stale = stale
        self.superseded = superseded
        self.orphaned = orphaned
        self.sourcesWithoutCurrentUnit = sourcesWithoutCurrentUnit
    }
}

/// Decides, unit by unit, which of a store's records describe the source as it is now.
///
/// `IndexFreshness` compares the newest unit with the newest source. That establishes that
/// *a* build ran after the last edit; it says nothing about any particular unit, and a store
/// accumulates units across build variants and toolchains. Ignite's held 461 units more than a
/// day old beside that day's, and reported "1m newer than the newest source".
///
/// The decision is a pure function of dates so that it can be tested without a store. What it
/// cannot see is stated in the `IndexStoreInfra` guide rather than left to be discovered: it
/// trusts modification times, it judges a unit by its *main* file alone, and it cannot tell a
/// file that is no longer compiled from one that has not been compiled yet.
public enum IndexUnitCurrency {

    /// Judges one unit.
    ///
    /// - Parameters:
    ///   - unitDate: When the unit was written.
    ///   - sourceDate: When the unit's main source file was last modified, or `nil` when the
    ///     file does not exist.
    ///   - newestSiblingDate: The date of the newest unit for the same source, module and
    ///     platform — this unit included.
    /// - Returns: The verdict. Staleness outranks supersession: a unit that predates its source
    ///   is wrong about the file whether or not something newer exists.
    public static func verdict(
        unitDate: Date, sourceDate: Date?, newestSiblingDate: Date
    ) -> IndexUnitVerdict {
        guard let sourceDate else { return .orphaned }
        if unitDate < sourceDate { return .stale }
        if unitDate < newestSiblingDate { return .superseded }
        return .current
    }

    /// The platform a unit was compiled for, with its deployment version removed.
    ///
    /// Two units for one source on *different* platforms are both right — each sees references
    /// the other's `#if os(…)` hides — so they must not supersede one another. Two units that
    /// differ only in deployment version, or in an older toolchain's `macosx12.0.0` spelling of
    /// `macos12.0`, are the same compilation recorded twice.
    ///
    /// - Parameter target: A target triple, e.g. `arm64-apple-ios17.0-simulator`.
    /// - Returns: Architecture, operating system and environment, e.g. `arm64-ios-simulator`.
    public static func platform(ofTarget target: String) -> String {
        let parts = target.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { return target }
        var system = String(parts[2].prefix { !$0.isNumber })
        if system == "macosx" { system = "macos" }
        return ([parts[0], system] + parts.dropFirst(3)).joined(separator: "-")
    }

    /// Judges every unit of a store.
    ///
    /// - Parameters:
    ///   - units: Every unit in the store.
    ///   - sourceDate: The modification date of a source file, or `nil` when it does not exist.
    ///     Injected so the decision can be exercised without touching the file system.
    /// - Returns: The units that may be read and a count of those that may not.
    public static func census(
        units: [IndexUnitRecord], sourceDate: (String) -> Date?
    ) -> IndexUnitCensus {
        struct Compilation: Hashable {
            let mainFile: String
            let moduleName: String
            let platform: String
        }
        let sourceUnits = units.filter(\.hasMainFile)

        var newest: [Compilation: Date] = [:]
        var keys: [Compilation] = []
        keys.reserveCapacity(sourceUnits.count)
        for unit in sourceUnits {
            let key = Compilation(
                mainFile: unit.mainFile, moduleName: unit.moduleName,
                platform: platform(ofTarget: unit.target))
            keys.append(key)
            if newest[key].map({ unit.modified > $0 }) ?? true { newest[key] = unit.modified }
        }

        var sourceDates: [String: Date?] = [:]
        var current: [String] = []
        var stale = 0, superseded = 0, orphaned = 0
        var hasStaleUnit: Set<String> = []
        var hasCurrentUnit: Set<String> = []

        for (unit, key) in zip(sourceUnits, keys) {
            let edited: Date?
            if let known = sourceDates[unit.mainFile] {
                edited = known
            } else {
                edited = sourceDate(unit.mainFile)
                sourceDates[unit.mainFile] = .some(edited)
            }
            let judged = verdict(
                unitDate: unit.modified, sourceDate: edited,
                newestSiblingDate: newest[key] ?? unit.modified)
            switch judged {
            case .current:
                current.append(unit.outputFile)
                hasCurrentUnit.insert(unit.mainFile)
            case .stale:
                stale += 1
                hasStaleUnit.insert(unit.mainFile)
            case .superseded:
                superseded += 1
            case .orphaned:
                orphaned += 1
            }
        }

        return IndexUnitCensus(
            currentOutputPaths: current,
            examined: sourceUnits.count,
            stale: stale, superseded: superseded, orphaned: orphaned,
            sourcesWithoutCurrentUnit: hasStaleUnit.subtracting(hasCurrentUnit).sorted())
    }
}

// MARK: - Diagnostics

extension IndexUnitCensus {

    /// The clause a freshness note appends: how many units were not read, and why.
    var ignoredClause: String {
        "\(ignored) ignored (\(stale) stale, \(superseded) superseded, \(orphaned) orphaned)"
    }

    /// The barrier for sources the index no longer describes.
    ///
    /// The per-file form of ``IndexFreshness/staleBarrier(checkerId:subject:storeURL:)``, and the
    /// same refusal under the same rule: the index is older than code it would be read against.
    /// The store-wide comparison cannot see this case — a later build of *something else* makes
    /// the newest unit newer than every source — and reading on would be worse than before the
    /// stale units were set aside, because their references are now absent rather than merely
    /// dated: everything only those files call would be reported as unreachable.
    ///
    /// - Parameters:
    ///   - checkerId: The checker's id, used to scope the rule identifier.
    ///   - subject: What the checker would have determined, as a noun phrase.
    ///   - storeURL: The store, named so the reader can inspect it.
    ///   - sources: The undescribed sources that matter to this checker — its own project's,
    ///     after its own exclusions. Passed rather than read from the census because the census
    ///     covers every unit in the store, dependencies included.
    /// - Returns: An error-severity diagnostic naming the count and the first few files.
    public func undescribedSourcesBarrier(
        checkerId: String, subject: String, storeURL: URL, sources: [String]
    ) -> Diagnostic {
        let ordered = sources.sorted()
        let shown = ordered.prefix(3)
            .map { ($0 as NSString).lastPathComponent }
            .joined(separator: ", ")
        let more = ordered.count > 3 ? ", and \(ordered.count - 3) more" : ""
        let files = ordered.count == 1 ? "1 source file was" : "\(ordered.count) source files were"
        return Diagnostic(
            severity: .error,
            message: """
                \(files) edited after every index unit that describes \
                \(ordered.count == 1 ? "it" : "them") was written, so \(subject) could not be \
                determined: \(shown)\(more). The store as a whole is newer than the newest \
                source, which is why this is not reported as a stale index — but nothing in it \
                describes these files as they are now, and what only they reference would be \
                reported as unreachable. \(examined) source units at \(storeURL.path); \
                \(ignoredClause).
                """,
            ruleId: "\(checkerId).index.stale-barrier",
            suggestedFix: """
                Build everything, tests included — `swift build --build-tests` — and re-run. \
                If a file listed here is no longer part of any target, the unit is left over \
                from a build that compiled it: remove the build directory, or the file.
                """
        )
    }
}

extension IndexFreshness {

    /// The provenance note for a run that examined its units one by one.
    ///
    /// The age of the newest unit was all the note used to say, and a store in which one unit in
    /// four is months old satisfies it. The count of what was set aside is the part that tells a
    /// reader whether the store is what they think it is.
    ///
    /// - Parameters:
    ///   - checkerId: The checker's id, used to scope the rule identifier.
    ///   - census: The unit census, or `nil` when units could not be examined individually —
    ///     in which case every unit was read and the note says so.
    /// - Returns: A note-severity diagnostic stating the index's age, size and what was ignored.
    public func coverageNote(checkerId: String, census: IndexUnitCensus?) -> Diagnostic {
        let base = coverageNote(checkerId: checkerId)
        let detail: String
        if let census {
            detail = " \(census.examined) compiled from source: \(census.currentOutputPaths.count) read, \(census.ignoredClause)."
        } else {
            detail = " The units were not examined individually, so any that predate their source were read as current."
        }
        return Diagnostic(
            severity: base.severity,
            message: base.message + detail,
            ruleId: base.ruleId
        )
    }
}
