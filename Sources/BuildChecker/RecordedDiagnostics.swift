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
/// ``collect(projectRoot:buildConfiguration:buildStarted:)`` reads them under three rules, and
/// reports what it could not establish instead of answering from part of the input:
///
/// - **Live** and **First-party** are applied by ``CompileUnitIndex``.
/// - **Current** — a record older than a source it was compiled from is not trusted.
///
/// A unit whose record is missing, unreadable or not current is counted in
/// ``Coverage/unverified``, and ``unverifiedDiagnostic`` turns that into a finding.
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

        /// Creates a coverage tally.
        ///
        /// - Parameters:
        ///   - mapCount: Output file maps found.
        ///   - unitCount: Live first-party compile units.
        ///   - compiledByThisRun: Units recompiled by this run's build.
        ///   - readFromRecord: Units read from a record this run did not rewrite.
        ///   - unverified: Units that could not be vouched for.
        public init(
            mapCount: Int,
            unitCount: Int,
            compiledByThisRun: Int,
            readFromRecord: Int,
            unverified: [String] = []
        ) {
            self.mapCount = mapCount
            self.unitCount = unitCount
            self.compiledByThisRun = compiledByThisRun
            self.readFromRecord = readFromRecord
            self.unverified = unverified
        }
    }

    /// Every diagnostic recorded for a current, readable unit, in unit order.
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
    /// - Returns: The recorded diagnostics and the coverage tally.
    public static func collect(
        index: CompileUnitIndex,
        projectRoot: String,
        buildStarted: Date
    ) -> RecordedDiagnostics {
        var diagnostics: [Diagnostic] = []
        var coverage = Coverage(
            mapCount: index.mapCount,
            unitCount: index.units.count,
            compiledByThisRun: 0,
            readFromRecord: 0
        )

        for unit in index.units {
            guard CompileUnitIndex.isCurrent(unit),
                  let written = CompileUnitIndex.modificationDate(atPath: unit.diagnosticsPath) else {
                coverage.unverified.append(displayName(of: unit, projectRoot: projectRoot))
                continue
            }
            do {
                diagnostics.append(contentsOf: try SerializedDiagnosticsReader.diagnostics(atPath: unit.diagnosticsPath))
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

        return RecordedDiagnostics(diagnostics: diagnostics, coverage: coverage)
    }

    /// The run-scoped note saying how the package's compile units were accounted for.
    ///
    /// It is the one line that distinguishes "clean" from "not looked at", so it is on every
    /// result. The count is of Swift compile units: C-family sources are not in an output file
    /// map, and their warnings are still reported only when the build recompiles them.
    public var coverageDiagnostic: Diagnostic {
        var message = "\(coverage.unitCount) Swift compile unit(s): "
            + "\(coverage.compiledByThisRun) compiled by this run, "
            + "\(coverage.readFromRecord) read from recorded diagnostics"
        if !coverage.unverified.isEmpty {
            message += ", \(coverage.unverified.count) not verified"
        }
        message += ". C-family sources are not counted; their warnings are reported only when recompiled."
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
