import ArgumentParser // logging: CLI tool — print() is appropriate for user-facing output
import Foundation
import QualityGateCore
import IJSSensor
import IJSAggregator

/// Review and manage auto-generated calibrations from diagnostic overrides.
struct Calibrate: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Review override calibrations and checker false-positive rates."
    )

    @Flag(name: .long, help: "Show per-rule override and calibration counts")
    var status: Bool = false

    @Flag(name: .long, help: "Show per-checker sample counts and false-positive rates")
    var coverage: Bool = false

    @Flag(name: .long, help: "Reclassify an auto-generated calibration")
    var reclassify: Bool = false

    @Option(name: .long, help: "Rule ID to reclassify (used with --reclassify)")
    var ruleId: String?

    @Option(name: .long, help: "File path of the override to reclassify")
    var file: String?

    @Option(name: .long, help: "Line number of the override to reclassify")
    var line: Int?

    @Option(name: .long, help: "New root cause classification (imprecise, structural, deferred, external, expedient)")
    var rootCause: String?

    @Option(name: .long, help: "Rationale for the reclassification")
    var rationale: String?

    @Option(name: .long, help: "Number of days to include in the report window (default: 30)")
    var windowDays: Int = 30

    @Option(name: .long, help: "Path to the IJS corpus directory (overrides .quality-gate.yml)")
    var corpusPath: String?

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    func validate() throws {
        let modeCount = [status, coverage, reclassify].filter { $0 }.count
        guard modeCount == 1 else {
            throw ValidationError("Specify exactly one of --status, --coverage, or --reclassify.")
        }

        if reclassify {
            guard ruleId != nil else {
                throw ValidationError("--reclassify requires --rule-id.")
            }
            guard rootCause != nil else {
                throw ValidationError("--reclassify requires --root-cause.")
            }
            guard rationale != nil else {
                throw ValidationError("--reclassify requires --rationale.")
            }
            let validCauses = ["imprecise", "structural", "deferred", "external", "expedient", "unclassified"]
            if let cause = rootCause, !validCauses.contains(cause) {
                throw ValidationError("--root-cause must be one of: \(validCauses.joined(separator: ", "))")
            }
        }
    }

    func run() async throws {
        var configuration: Configuration
        do {
            configuration = try Configuration.load(from: config)
        } catch { // logging: falling back to default configuration
            configuration = Configuration()
        }

        let effectiveCorpusPath = corpusPath ?? configuration.consistency.corpusPath
        guard let effectiveCorpusPath else {
            print("[calibrate] Error: No corpus path configured. Set consistency.corpusPath in .quality-gate.yml or use --corpus-path.") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        let projectID = configuration.consistency.projectID
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
        let corpus = CorpusPath(basePath: effectiveCorpusPath, projectID: projectID)
        let writer = TelemetryWriter()

        let now = Date()
        guard let windowStart = Calendar.current.date(byAdding: .day, value: -windowDays, to: now) else {
            print("[calibrate] Error: Cannot compute window start date") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        if status {
            try await runStatus(writer: writer, corpus: corpus, windowStart: windowStart, windowEnd: now)
        } else if coverage {
            try await runCoverage(writer: writer, corpus: corpus, windowStart: windowStart, windowEnd: now)
        } else if reclassify {
            try await runReclassify(writer: writer, corpus: corpus)
        }
    }

    // MARK: - Status

    private func runStatus(
        writer: TelemetryWriter,
        corpus: CorpusPath,
        windowStart: Date,
        windowEnd: Date
    ) async throws {
        let metadata = try await writer.readMetadata(from: corpus, startDate: windowStart, endDate: windowEnd)
        let calibrations = try await writer.readCalibrations(from: corpus, startDate: windowStart, endDate: windowEnd)

        let rows = CalibrationReport.status(metadata: metadata, calibrations: calibrations)

        print("Calibration Status (\(corpus.projectID))") // logging: CLI user-facing output
        print("  Window: \(windowDays) days\n") // logging: CLI user-facing output

        if rows.isEmpty {
            print("  No overrides or calibrations found in this window.") // logging: CLI user-facing output
            return
        }

        print("  \(pad("Rule", to: 40)) \(lpad("Overrides", to: 10)) \(lpad("Calibrated", to: 10)) \(lpad("Unclassified", to: 12))") // logging: CLI user-facing output
        print("  " + String(repeating: "\u{2500}", count: 74)) // logging: CLI user-facing output

        var totalOverrides = 0
        var totalCalibrated = 0
        var totalUnclassified = 0

        for row in rows {
            print("  \(pad(row.ruleId, to: 40)) \(lpad("\(row.overrideCount)", to: 10)) \(lpad("\(row.calibratedCount)", to: 10)) \(lpad("\(row.unclassifiedCount)", to: 12))") // logging: CLI user-facing output
            totalOverrides += row.overrideCount
            totalCalibrated += row.calibratedCount
            totalUnclassified += row.unclassifiedCount
        }

        print("")  // logging: CLI user-facing output
        print("  Total: \(totalOverrides) overrides, \(totalCalibrated) calibrated, \(totalUnclassified) need manual review") // logging: CLI user-facing output
    }

    // MARK: - Coverage

    private func runCoverage(
        writer: TelemetryWriter,
        corpus: CorpusPath,
        windowStart: Date,
        windowEnd: Date
    ) async throws {
        let metadata = try await writer.readMetadata(from: corpus, startDate: windowStart, endDate: windowEnd)
        let calibrations = try await writer.readCalibrations(from: corpus, startDate: windowStart, endDate: windowEnd)

        let rows = CalibrationReport.coverage(metadata: metadata, calibrations: calibrations)

        print("Checker Coverage (\(corpus.projectID))") // logging: CLI user-facing output
        print("  Window: \(windowDays) days\n") // logging: CLI user-facing output

        if rows.isEmpty {
            print("  No checker data found in this window.") // logging: CLI user-facing output
            return
        }

        print("  \(pad("Checker", to: 24)) \(lpad("Samples", to: 8)) \(pad("Validity", to: 14)) \(lpad("Calibrations", to: 12)) \(lpad("FP Rate", to: 8))") // logging: CLI user-facing output
        print("  " + String(repeating: "\u{2500}", count: 68)) // logging: CLI user-facing output

        var checkersAtValidity = 0
        var checkersTuning: [String] = []

        for row in rows {
            let fpStr: String
            if let rate = row.falsePositiveRate {
                fpStr = "\(Int((rate * 100).rounded()))%"
            } else {
                fpStr = "\u{2014}"
            }
            print("  \(pad(row.checkerId, to: 24)) \(lpad("\(row.sampleCount)", to: 8)) \(pad(row.validity.rawValue, to: 14)) \(lpad("\(row.calibrationCount)", to: 12)) \(lpad(fpStr, to: 8))") // logging: CLI user-facing output

            if row.validity == .valid {
                checkersAtValidity += 1
                if let rate = row.falsePositiveRate, rate > 0.5 {
                    checkersTuning.append(row.checkerId)
                }
            }
        }

        print("") // logging: CLI user-facing output
        var summary = "  Checkers at validity: \(checkersAtValidity) of \(rows.count)"
        if !checkersTuning.isEmpty {
            summary += " (\(checkersTuning.joined(separator: ", ")) FP rate suggests checker tuning)"
        }
        print(summary) // logging: CLI user-facing output
    }

    // MARK: - Reclassify

    private static let rootCauseToStep: [String: FiveStepStage] = [
        "imprecise": .diagnosis,
        "structural": .design,
        "deferred": .doing,
        "external": .design,
        "expedient": .diagnosis,
        "unclassified": .diagnosis,
    ]

    private func runReclassify(writer: TelemetryWriter, corpus: CorpusPath) async throws {
        guard let ruleId, let rootCause, let rationale else { return }

        let location = file ?? "unknown file"
        let failedStep = Self.rootCauseToStep[rootCause] ?? .diagnosis
        let author = ProcessInfo.processInfo.environment["USER"] ?? "local"

        let calibration = JudgmentCalibration(
            date: Date(),
            decisionOwner: author,
            practitioner: author,
            riskTier: .operational,
            rootCauseAnalysis: RootCauseAnalysis(
                proximateCause: "Override of \(ruleId): manual reclassification",
                chainOfInquiry: [rationale],
                rootCause: rootCause,
                failedStep: failedStep,
                isRecurringPattern: false
            ),
            redTeamDissent: "Manual reclassification of \(ruleId) at \(location) — verify the \(rootCause) classification is accurate.",
            proposedPolicyUpdate: nil,
            pulseContribution: "Reclassified \(ruleId) override at \(location) as \(rootCause): \(rationale)"
        )

        let metadata = CheckResultMetadata(
            projectID: corpus.projectID,
            timestamp: Date(),
            environment: .local,
            decisionOwner: author,
            results: [],
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil
        )

        try await writer.write(metadata: metadata, calibrations: [calibration], to: corpus)

        print("[calibrate] Reclassified \(ruleId) at \(location) as \(rootCause)") // logging: CLI user-facing output
        if let line {
            print("[calibrate] Line: \(line)") // logging: CLI user-facing output
        }
        print("[calibrate] Rationale: \(rationale)") // logging: CLI user-facing output
        print("[calibrate] Written to corpus at \(corpus.projectDirectory)") // logging: CLI user-facing output
    }

    // MARK: - Formatting

    private func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private func lpad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}
