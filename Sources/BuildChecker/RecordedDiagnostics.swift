import Foundation
import QualityGateCore
import QualityGateLogging

/// What the compiler recorded for every first-party compile unit of a finished build.
///
/// `swift build` prints a diagnostic only while compiling the file that carries it, and compiles
/// only what is out of date. Its output is therefore the warnings of the files *this* invocation
/// happened to rebuild — a function of the build directory's history, not of the sources. The
/// compiler's serialized diagnostics do not have that property: each compile job's `.dia` is
/// rewritten when the job runs and kept when it does not, so together they describe the whole
/// package whether or not anything was recompiled.
///
/// ``collect(projectRoot:buildConfiguration:buildStarted:)`` reads them under these rules, and
/// reports what it could not establish instead of answering from part of the input:
///
/// - **Live**, **Of this build** and **First-party** are applied by ``CompileUnitIndex``.
/// - **Current** — a record older than a source it was compiled from is not trusted.
/// - **Not stale** — a diagnostic is evidence about the file it points at *as it was when the
///   record holding it was written*. One that points at a file changed since is discarded.
///
/// A unit whose record is missing, unreadable or not current is counted in
/// ``Coverage/unverified``, and ``unverifiedDiagnostic`` turns that into a finding.
///
/// ## Why a record can be stale when its unit is current
///
/// A record is not only about its own source. The compiler writes a diagnostic about `F.swift`
/// into other units' records as well — every primary file of a batch that contains a macro
/// expansion receives the batch's diagnostics, so a warning in one Swift Testing file is also
/// in the records of the four or five files compiled beside it. When `F.swift` is edited, only
/// `F`'s unit is recompiled. Its record is rewritten; the siblings' are not, and still describe
/// `F` as it was, at lines that have since moved or been fixed. Each of those records is
/// *current* — it is no older than its own source — and wrong about `F`.
///
/// The file's modification date decides, not whether the file's own record is newer than the
/// sibling's: a file is recompiled whenever something it depends on changes, without being
/// edited, and what a sibling recorded about it is then still true.
///
/// ## Usage
///
/// ```swift
/// import BuildChecker
/// import Foundation
///
/// let buildStarted = Date()
/// // … run `swift build` and see it exit 0 …
/// let recorded = RecordedDiagnostics.collect(
///     projectRoot: "/path/to/package",
///     buildConfiguration: nil,
///     buildStarted: buildStarted
/// )
/// print(recorded.coverageDiagnostic.message)
/// ```
public struct RecordedDiagnostics: Sendable, Equatable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "RecordedDiagnostics")

    /// The rule identifier of the per-run coverage note.
    public static let coverageRuleId = "build.diagnostic-coverage"

    /// The rule identifier of the finding raised when some unit's record could not be vouched for.
    public static let unverifiedRuleId = "build.warnings-unverified"

    /// The severity of ``unverifiedRuleId``.
    ///
    /// A warning: "this run cannot say the package is warning-free" is a reason not to pass
    /// under a zero-warnings bar. This is the one place to change if measurement across the
    /// portfolio shows it firing where nothing is wrong.
    public static let unverifiedSeverity: Diagnostic.Severity = .warning

    /// The build configuration `swift build` uses when none is named.
    public static let defaultBuildConfiguration = "debug"

    /// How much of the package the recorded diagnostics account for.
    public struct Coverage: Sendable, Equatable {
        /// Output file maps found for the configuration. Zero means the build layout was not
        /// recognised and nothing could be read.
        public var mapCount: Int
        /// Live first-party Swift compile units named by those maps.
        public var unitCount: Int
        /// Units whose record was written by this run's build.
        public var compiledByThisRun: Int
        /// Units this run's build left alone, whose diagnostics come from the standing record.
        public var readFromRecord: Int
        /// Units whose record was missing, unreadable or older than its source — each named by
        /// its source path relative to the project root.
        public var unverified: [String]
        /// Distinct recorded diagnostics discarded because the file they point at changed after
        /// the record holding them was written. Notes are not counted; they
        /// go with the diagnostic they belong to.
        public var staleDiagnostics: Int
        /// Live first-party units named only by an output file map the build that just ran does
        /// not name. Not in ``unitCount``, not read, and not in ``unverified``.
        public var orphanedUnits: Int
        /// The output file maps those units were named by.
        public var orphanedMaps: Int

        /// Creates a coverage tally.
        ///
        /// - Parameters:
        ///   - mapCount: Output file maps found.
        ///   - unitCount: Live first-party compile units.
        ///   - compiledByThisRun: Units recompiled by this run's build.
        ///   - readFromRecord: Units read from a record this run did not rewrite.
        ///   - unverified: Units that could not be vouched for.
        ///   - staleDiagnostics: Distinct diagnostics discarded as stale.
        ///   - orphanedUnits: Units ignored because the build that just ran does not name them.
        ///   - orphanedMaps: The output file maps those units were named by.
        public init(
            mapCount: Int,
            unitCount: Int,
            compiledByThisRun: Int,
            readFromRecord: Int,
            unverified: [String] = [],
            staleDiagnostics: Int = 0,
            orphanedUnits: Int = 0,
            orphanedMaps: Int = 0
        ) {
            self.mapCount = mapCount
            self.unitCount = unitCount
            self.compiledByThisRun = compiledByThisRun
            self.readFromRecord = readFromRecord
            self.unverified = unverified
            self.staleDiagnostics = staleDiagnostics
            self.orphanedUnits = orphanedUnits
            self.orphanedMaps = orphanedMaps
        }
    }

    /// Every diagnostic recorded for a current, readable unit that is not stale, in unit order.
    public var diagnostics: [Diagnostic]

    /// What was and was not read.
    public var coverage: Coverage

    /// Creates a value from diagnostics already collected.
    ///
    /// - Parameters:
    ///   - diagnostics: The recorded diagnostics.
    ///   - coverage: What was and was not read.
    public init(diagnostics: [Diagnostic], coverage: Coverage) {
        self.diagnostics = diagnostics
        self.coverage = coverage
    }

    /// Reads the recorded diagnostics of a package's build directory.
    ///
    /// Call it only after `swift build` exited 0. After a failure not every unit ran, and the
    /// failing file's record is the previous build's.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root; its `.build` is read.
    ///   - buildConfiguration: The configuration that was built, `nil` for the default.
    ///   - buildStarted: The moment the build was started. A record at least this new was
    ///     written by this run.
    /// - Returns: The recorded diagnostics and the coverage tally.
    public static func collect(
        projectRoot: String,
        buildConfiguration: String?,
        buildStarted: Date
    ) -> RecordedDiagnostics {
        let buildDirectory = (projectRoot as NSString).appendingPathComponent(".build")
        let index = CompileUnitIndex.scan(
            buildDirectory: buildDirectory,
            configuration: buildConfiguration ?? defaultBuildConfiguration
        )
        return collect(index: index, projectRoot: projectRoot, buildStarted: buildStarted)
    }

    /// Reads the recorded diagnostics of the units in an index.
    ///
    /// - Parameters:
    ///   - index: The compile units to read.
    ///   - projectRoot: The package root, used to name unverified units relative to it.
    ///   - buildStarted: The moment the build was started.
    ///   - read: Decodes the record at a path. The default reads the `.dia` file; a test passes
    ///     its own to say what a record holds without writing a bitstream.
    /// - Returns: The recorded diagnostics and the coverage tally.
    public static func collect(
        index: CompileUnitIndex,
        projectRoot: String,
        buildStarted: Date,
        read: (String) throws -> [Diagnostic] = SerializedDiagnosticsReader.diagnostics(atPath:)
    ) -> RecordedDiagnostics {
        var diagnostics: [Diagnostic] = []
        var stale: [Diagnostic] = []
        var coverage = Coverage(
            mapCount: index.mapCount,
            unitCount: index.units.count,
            compiledByThisRun: 0,
            readFromRecord: 0,
            orphanedUnits: index.orphanedUnitCount,
            orphanedMaps: index.orphanedMaps.count
        )

        for unit in index.units {
            guard CompileUnitIndex.isCurrent(unit),
                  let written = CompileUnitIndex.modificationDate(atPath: unit.diagnosticsPath) else {
                coverage.unverified.append(displayName(of: unit, projectRoot: projectRoot))
                continue
            }
            do {
                let separated = separatingStale(try read(unit.diagnosticsPath), recordWritten: written)
                diagnostics.append(contentsOf: separated.current)
                stale.append(contentsOf: separated.stale)
            } catch {
                logger.debug("Unreadable record \(unit.diagnosticsPath, privacy: .public): \(String(describing: error), privacy: .public)")
                coverage.unverified.append(displayName(of: unit, projectRoot: projectRoot))
                continue
            }
            if written >= buildStarted {
                coverage.compiledByThisRun += 1
            } else {
                coverage.readFromRecord += 1
            }
        }

        // The same stale diagnostic sits in every sibling record of its batch; it is one.
        coverage.staleDiagnostics = BuildChecker.uniqued(stale).count
        return RecordedDiagnostics(diagnostics: diagnostics, coverage: coverage)
    }

    /// Splits one record's diagnostics into those still true of the files they point at and
    /// those recorded before such a file last changed.
    ///
    /// A diagnostic and the notes that follow it are one finding and are kept or discarded
    /// together, judged by where the diagnostic itself points:
    ///
    /// - **It has no location** — kept. There is no file for it to be stale against.
    /// - **Its file is an ordinary one, on disk** — stale when the file was modified after the
    ///   record was written. Notes are not consulted: a warning in `G.swift` about a
    ///   conformance, with a note pointing at the witness in `F.swift`, is the compiler's
    ///   verdict on `G`, and stands while `G`'s unit is current.
    /// - **It is inside a macro expansion** — the compiler locates it in a generated buffer
    ///   (`…/swift-generated-sources/@__swiftmacro_…swift`) and attaches a note at the expansion
    ///   site. The buffer is written under the temporary directory once and not touched again
    ///   when the site is fixed, so its own date vouches for nothing: the diagnostic is stale
    ///   when the buffer *or any file its notes point at* changed after the record was written.
    /// - **Its file is not on disk** — judged by its notes in the same way. When none of those
    ///   exists either there is nothing to compare the record with, and it is kept, as it
    ///   always was. (A file that was *deleted* does not arrive this way through a sibling's
    ///   record: removing a source changes the target's file list, and the build recompiles
    ///   every unit of the target. Measured, 60 of 60.)
    ///
    /// A unit's own source can never make its own record stale — ``CompileUnitIndex/isCurrent(_:)``
    /// has already required the record to be no older than it — so this only ever discards
    /// what a record says about *another* file: a sibling, a header, a generated source.
    ///
    /// - Parameters:
    ///   - diagnostics: One record's diagnostics, in file order: each diagnostic followed by
    ///     its notes.
    ///   - recordWritten: The record's modification date.
    /// - Returns: The diagnostics to report, and the stale ones without their notes.
    static func separatingStale(
        _ diagnostics: [Diagnostic],
        recordWritten: Date
    ) -> (current: [Diagnostic], stale: [Diagnostic]) {
        var current: [Diagnostic] = []
        var stale: [Diagnostic] = []
        var index = diagnostics.startIndex
        while index < diagnostics.endIndex {
            let head = diagnostics[index]
            var end = diagnostics.index(after: index)
            while end < diagnostics.endIndex, diagnostics[end].severity == .note {
                end = diagnostics.index(after: end)
            }
            let notes = diagnostics[diagnostics.index(after: index)..<end]
            if isStale(head, notes: notes, recordWritten: recordWritten) {
                stale.append(head)
            } else {
                current.append(head)
                current.append(contentsOf: notes)
            }
            index = end
        }
        return (current, stale)
    }

    /// How the compiler names the buffer it expands a macro into.
    static let macroExpansionBufferPrefix = "@__swiftmacro_"

    /// Whether a diagnostic was recorded before the file it points at last changed.
    private static func isStale(
        _ diagnostic: Diagnostic,
        notes: ArraySlice<Diagnostic>,
        recordWritten: Date
    ) -> Bool {
        guard let path = diagnostic.filePath else { return false }
        let edited = CompileUnitIndex.modificationDate(atPath: path)
        let isExpansion = (path as NSString).lastPathComponent.hasPrefix(macroExpansionBufferPrefix)
        if let edited, !isExpansion {
            return edited > recordWritten
        }
        let sites = notes.compactMap(\.filePath).compactMap(CompileUnitIndex.modificationDate(atPath:))
        return ((edited.map { [$0] } ?? []) + sites).contains { $0 > recordWritten }
    }

    /// The run-scoped note saying how the package's compile units were accounted for.
    ///
    /// It is the one line that distinguishes "clean" from "not looked at", so it is on every
    /// result — and it says what was looked at and set aside: diagnostics discarded as stale,
    /// and units ignored because they belong to a build that is gone. The count is of Swift
    /// compile units: C-family sources are not in an output file
    /// map, and their warnings are still reported only when the build recompiles them.
    public var coverageDiagnostic: Diagnostic {
        var message = "\(coverage.unitCount) Swift compile unit(s): "
            + "\(coverage.compiledByThisRun) compiled by this run, "
            + "\(coverage.readFromRecord) read from recorded diagnostics"
        if !coverage.unverified.isEmpty {
            message += ", \(coverage.unverified.count) not verified"
        }
        message += "."
        if coverage.staleDiagnostics > 0 {
            message += " \(coverage.staleDiagnostics) recorded diagnostic(s) discarded as stale: "
                + "the file each points at changed after the record holding it was written."
        }
        if coverage.orphanedUnits > 0 {
            message += " \(coverage.orphanedUnits) compile unit(s) in \(coverage.orphanedMaps) "
                + "output file map(s) ignored as orphaned: the build that just ran does not name them."
        }
        message += " C-family sources are not counted; their warnings are reported only when recompiled."
        return Diagnostic(severity: .note, message: message, ruleId: Self.coverageRuleId)
    }

    /// The finding raised when a pass cannot be vouched for, or `nil` when every unit was read.
    ///
    /// Raised when no output file map was found at all — an unknown build layout, or a future
    /// toolchain — and when any live first-party unit has no readable, current record.
    public var unverifiedDiagnostic: Diagnostic? {
        let remedy = "A clean build (`rm -rf .build`) reports them."
        if coverage.mapCount == 0 {
            return Diagnostic(
                severity: Self.unverifiedSeverity,
                message: "No output file map was found in the build directory, so the recorded "
                    + "diagnostics of up-to-date compile units could not be read. Warnings in files "
                    + "this build did not recompile, if any, are not in this report. \(remedy)",
                ruleId: Self.unverifiedRuleId
            )
        }
        guard let first = coverage.unverified.first else { return nil }
        return Diagnostic(
            severity: Self.unverifiedSeverity,
            message: "\(coverage.unverified.count) of \(coverage.unitCount) compile units were up to "
                + "date and their recorded diagnostics could not be read (first: `\(first)`). "
                + "Warnings in those files, if any, are not in this report. \(remedy)",
            ruleId: Self.unverifiedRuleId
        )
    }

    /// Names a unit for a message: its source relative to the project root, or for a
    /// module-level unit the record's file name.
    static func displayName(of unit: CompileUnit, projectRoot: String) -> String {
        guard let source = unit.source else {
            return (unit.diagnosticsPath as NSString).lastPathComponent
        }
        let rootComponents = URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().pathComponents
        let sourceComponents = URL(fileURLWithPath: source).resolvingSymlinksInPath().pathComponents
        guard sourceComponents.count > rootComponents.count,
              Array(sourceComponents.prefix(rootComponents.count)) == rootComponents else {
            return source
        }
        return sourceComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
