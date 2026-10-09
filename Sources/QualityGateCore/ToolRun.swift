import Foundation

/// How busy the machine was, sampled at the moment a tool run ended.
///
/// A budget is wall-clock time, and wall-clock time is a statement about the machine as much
/// as about the work. A suite that takes four minutes alone took more than fifteen while
/// three other sessions were building, and the run that was cut off said nothing about either
/// number. The load does not excuse a timeout — the run is still incomplete — but it is the
/// one fact that tells a reader whether to rerun or to raise the budget.
public struct MachineLoad: Sendable, Equatable, CustomStringConvertible {

    /// The one-minute load average: runnable work, averaged over the last minute.
    public let oneMinute: Double

    /// The number of processors the system has made available.
    public let activeProcessors: Int

    /// Creates a reading.
    public init(oneMinute: Double, activeProcessors: Int) {
        self.oneMinute = oneMinute
        self.activeProcessors = activeProcessors
    }

    /// The machine's load now, or `nil` where the system will not report one.
    public static func current() -> MachineLoad? {
        var samples = [Double](repeating: 0, count: 3)
        guard getloadavg(&samples, 3) >= 1, let first = samples.first, first.isFinite else {
            return nil
        }
        return MachineLoad(
            oneMinute: first, activeProcessors: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// The load as a report line states it: the figure, the cores, and the figure per core.
    public var description: String {
        let figure = "1-minute load average \(ToolRun.oneDecimal(oneMinute))"
        guard activeProcessors > 0 else { return figure }
        let perCore = oneMinute / Double(activeProcessors)
        let cores = activeProcessors == 1 ? "1 core" : "\(activeProcessors) cores"
        return "\(figure) on \(cores) (\(ToolRun.oneDecimal(perCore)) per core)"
    }
}

/// What one launch of a build tool produced, with everything a reader needs when it did not
/// end in a finding: the command, the budget it ran under, how long it took, and the load.
///
/// ## Why this exists
///
/// `build`, `test`, `doc-lint` and `xcode-build` each launch a tool that can run for minutes,
/// and each reported the two non-findings — *stopped at the budget* and *failed in a shape no
/// parser knows* — in its own way or not at all. A cut-off `swift test` was a signing
/// warning; a cut-off `swift build` was `build-unparsed-failure` with "exit 124" in it; a
/// cut-off DocC build was `✗ FAILED` and no diagnostic. None named the budget, and none said
/// what to do. One type means the four say the same thing, and the next checker to launch a
/// tool gets it by construction.
public struct ToolRun: Sendable, Equatable {

    /// The checker that launched the tool.
    public let checkerId: String
    /// The command as a person would type it: the tool's name and its arguments.
    public let command: String
    /// Where it ran, or `nil` for the gate's own working directory.
    public let directory: String?
    /// Standard output.
    public let stdout: String
    /// Standard error, including the process kernel's note when the run was terminated.
    public let stderr: String
    /// The exit code; 124 when the process kernel terminated the run at its budget.
    public let exitCode: Int32
    /// The budget the run was given, and where that figure came from.
    public let budget: CheckerBudget.Allowance
    /// Wall-clock seconds from launch to the tool's end.
    public let elapsed: TimeInterval
    /// The machine's load when the run ended, or `nil` if it could not be read.
    public let load: MachineLoad?

    /// Creates a record of a run.
    public init(
        checkerId: String,
        command: String,
        directory: String?,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        budget: CheckerBudget.Allowance,
        elapsed: TimeInterval,
        load: MachineLoad?
    ) {
        self.checkerId = checkerId
        self.command = command
        self.directory = directory
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.budget = budget
        self.elapsed = elapsed
        self.load = load
    }

    /// A run reconstructed from a transcript alone, for callers that hold a tool's output
    /// and exit code but not the record of launching it.
    ///
    /// The budget is the figure the process kernel named when it terminated the run, or the
    /// runner's default when the transcript carries no such note; the load is unknown.
    ///
    /// - Parameters:
    ///   - checkerId: The checker the transcript belongs to.
    ///   - command: The command that produced it.
    ///   - output: Everything the tool printed.
    ///   - exitCode: How it exited.
    ///   - elapsed: How long it ran.
    public init(
        transcriptOf command: String,
        checkerId: String,
        output: String,
        exitCode: Int32,
        elapsed: Duration
    ) {
        let reported = Self.kernelReportedBudget(in: output)
        self.init(
            checkerId: checkerId,
            command: command,
            directory: nil,
            stdout: output,
            stderr: "",
            exitCode: exitCode,
            budget: CheckerBudget.Allowance(
                checkerId: checkerId,
                seconds: reported ?? CheckerBudget.runnerDefault,
                source: reported == nil ? .runnerDefault : .reportedByRunner),
            elapsed: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) * 1e-18,
            load: nil)
    }

    /// The budget the process kernel named in its termination note, if `output` has one.
    static func kernelReportedBudget(in output: String) -> TimeInterval? {
        let marker = " timed out after "
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("process-kernel:") {
            guard let range = line.range(of: marker) else { continue }
            let figure = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
            if let seconds = TimeInterval(figure), seconds.isFinite, seconds >= 0 { return seconds }
        }
        return nil
    }

    /// Standard output followed by standard error, as the checkers' parsers read it.
    public var output: String { stdout + "\n" + stderr }

    // MARK: - Expiry

    /// The exit code the process kernel answers a timeout with.
    public static let expiryExitCode: Int32 = 124

    /// Whether the run was terminated at its budget.
    ///
    /// Either sign is enough: the exit code alone still means a timeout if the kernel's note
    /// was lost, and the note alone still means one if something upstream rewrote the code.
    /// The note is matched as the kernel writes it — a line of its own beginning
    /// `process-kernel:` — so a tool that merely prints the words "timed out" is not mistaken
    /// for one that was stopped.
    public var expired: Bool {
        exitCode == Self.expiryExitCode || Self.kernelReportedExpiry(in: stderr)
            || Self.kernelReportedExpiry(in: stdout)
    }

    /// Whether `output` carries the process kernel's own note that it terminated the run.
    public static func kernelReportedExpiry(in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            line.hasPrefix("process-kernel:") && line.contains(" timed out after ")
        }
    }

    /// The rule id under which `checkerId` reports a run stopped at its budget.
    public static func expiryRuleId(for checkerId: String) -> String {
        "\(checkerId)\(expiryRuleSuffix)"
    }

    /// Whether `diagnostic` reports a run stopped at its budget.
    ///
    /// The result cache asks this. A run that never finished has no verdict to replay, so a
    /// result carrying one of these is not stored whatever status the checker gave it.
    public static func isExpiry(_ diagnostic: Diagnostic) -> Bool {
        diagnostic.ruleId?.hasSuffix(expiryRuleSuffix) ?? false
    }

    private static let expiryRuleSuffix = "-timeout"

    /// The finding for a run that was stopped at its budget.
    ///
    /// An error, always: whatever the tool had printed before it was stopped — including a
    /// "passed" line for the part that finished — is not the run.
    public func expiryDiagnostic() -> Diagnostic {
        let headline = "`\(command)` was stopped at its time budget and did not finish. "
            + "This run is incomplete: it is not a pass, and it is not a finding about the code."
        let raised = Self.figure(budget.seconds * 2)
        let fix = "Rerun this checker alone, when the load is lower: "
            + "`quality-gate --check \(checkerId)`. If it needs longer than "
            + "\(Self.seconds(budget.seconds)) on a quiet machine, raise its budget in "
            + ".quality-gate.yml — `budgets:` then `\(checkerId): \(raised)` (seconds)."
        return Diagnostic(
            severity: .error,
            message: ([headline] + facts + quotedTail(errorLines: false)).joined(separator: "\n"),
            ruleId: Self.expiryRuleId(for: checkerId),
            suggestedFix: fix
        )
    }

    // MARK: - A failure no parser recognised

    /// The finding for a run that failed without printing anything the checker could parse.
    ///
    /// Carries the same facts as an expiry, and says in so many words that the budget was not
    /// the cause — the two are confused often enough that the denial is worth a sentence.
    /// The tool's own `error:` lines lead the quotation when they fall outside the tail:
    /// SwiftPM reports a failed checkout once and then prints a screen of progress, so the
    /// last twenty lines are routinely the wrong twenty.
    ///
    /// - Parameter ruleId: The checker's rule id for this finding.
    public func unparsedFailureDiagnostic(ruleId: String) -> Diagnostic {
        let headline = "`\(command)` exited \(exitCode) and nothing it printed is a diagnostic "
            + "this checker can parse. It was not stopped by its time budget."
        var fix = "Rerun this checker alone: `quality-gate --check \(checkerId)`. "
            + "For the whole transcript, run `\(command)`"
        fix += directory.map { " in \($0)." } ?? "."
        return Diagnostic(
            severity: .error,
            message: ([headline] + facts + quotedTail(errorLines: true)).joined(separator: "\n"),
            ruleId: ruleId,
            suggestedFix: fix
        )
    }

    // MARK: - The parts of a message

    /// How many trailing lines of a tool's output a message quotes.
    static let tailLength = 20

    /// The run's facts, one per line, under the headline.
    private var facts: [String] {
        [
            "  checker: \(checkerId)",
            "  budget:  \(Self.seconds(budget.seconds)) — \(budget.explanation)",
            "  elapsed: \(Self.seconds(elapsed))",
            "  load:    \(load?.description ?? "not available on this platform")",
        ]
    }

    /// One line of a tool's output, as quoted and as the tool indented it.
    private struct ToolLine {
        /// The line without surrounding whitespace, which is how it is quoted.
        let text: String
        /// Whether the tool indented it — how SwiftPM continues an error onto a second line.
        let indented: Bool
    }

    /// The tool's own lines: output with escapes removed, without blank lines and without the
    /// kernel's note, which the headline already states.
    private var toolLines: [ToolLine] {
        Self.removingTerminalEscapes(output)
            .split(whereSeparator: \.isNewline)
            .map { line in
                ToolLine(
                    text: line.trimmingCharacters(in: .whitespaces),
                    indented: line.first?.isWhitespace ?? false)
            }
            .filter { !$0.text.isEmpty && !$0.text.hasPrefix("process-kernel:") }
    }

    /// The quoted end of the output, preceded — when asked — by error lines it would miss.
    private func quotedTail(errorLines: Bool) -> [String] {
        let lines = toolLines
        guard !lines.isEmpty else {
            return ["  the tool had printed nothing when it \(expired ? "was stopped" : "exited")"]
        }
        let tail = lines.suffix(Self.tailLength)
        var quoted: [String] = []
        if errorLines {
            let earlier = Self.errorBlocks(in: Array(lines.dropLast(tail.count)))
            if !earlier.isEmpty {
                quoted.append("  what the tool reported as an error, outside the lines quoted below:")
                quoted += earlier.prefix(Self.tailLength).map { "    | \($0)" }
            }
        }
        let count = tail.count == lines.count
            ? "last \(tail.count) line\(tail.count == 1 ? "" : "s")"
            : "last \(tail.count) of \(lines.count) lines"
        quoted.append("  \(count) of output:")
        quoted += tail.map { "    | \($0.text)" }
        return quoted
    }

    /// The lines the tool marked as errors, each with the indented lines that continue it.
    ///
    /// SwiftPM reports a failed checkout as `error: … Couldn’t check out revision …:` and
    /// puts git's own reason — `fatal: unable to read tree` — on the next line, indented.
    /// The second line is the cause, so the block is kept whole.
    private static func errorBlocks(in lines: [ToolLine]) -> [String] {
        var blocks: [String] = []
        var continuing = false
        for line in lines {
            if line.text.hasPrefix("error:") || line.text.contains(": error:") {
                blocks.append(line.text)
                continuing = true
            } else if continuing && line.indented {
                blocks.append(line.text)
            } else {
                continuing = false
            }
        }
        return blocks
    }

    /// Removes terminal escape sequences: ANSI SGR colour (`ESC[…m`) and OSC 8 hyperlinks
    /// (`ESC]8;…;URI` terminated by `ESC\` or BEL).
    ///
    /// `swift build` colourises diagnostics even when its output is a pipe, and wraps a
    /// diagnostic's group in a hyperlink to its documentation. A quoted line is text.
    ///
    /// - Parameter text: Raw tool output, possibly colourised.
    /// - Returns: The same text with SGR and OSC 8 escape sequences removed.
    public static func removingTerminalEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text
            .replacingOccurrences(
                of: "\u{1B}\\]8;[^\u{1B}\u{07}]*(?:\u{1B}\\\\|\u{07})",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m",
                with: "",
                options: .regularExpression
            )
    }

    /// A duration as a report states it: whole seconds from ten up, one decimal below.
    ///
    /// Interpolation rather than `String(format:)` or `.formatted()`: the first bridges to
    /// the C printf ABI and the second is locale-aware, and a figure a person may paste into
    /// a YAML file has to read the same everywhere.
    static func seconds(_ interval: TimeInterval) -> String {
        "\(figure(interval))s"
    }

    /// The number in ``seconds(_:)``, without its unit.
    static func figure(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "\(interval)" }
        if interval >= 10, let whole = Int(exactly: interval.rounded()) {
            return "\(whole)"
        }
        let tenths = (interval * 10).rounded()
        if let whole = Int(exactly: tenths), whole.isMultiple(of: 10) {
            return "\(whole / 10)"
        }
        return oneDecimal(interval)
    }

    /// A figure rounded to one decimal place, always showing that place.
    static func oneDecimal(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        return "\((value * 10).rounded() / 10)"
    }
}

/// Launches a build tool under a budget and records what happened.
///
/// The three things a test must control are the three things injected: what starts the
/// process, the clock the elapsed time is read from, and the load reading. ``live`` binds
/// them to the process kernel, the system's monotonic uptime and `getloadavg`.
public struct ToolLauncher: Sendable {

    /// What a checker asks to have run.
    public struct Request: Sendable {
        /// The checker making the request.
        public let checkerId: String
        /// Absolute path of the executable.
        public let executable: String
        /// Its arguments.
        public let arguments: [String]
        /// Working directory, or `nil` to inherit the gate's.
        public let directory: String?
        /// The complete environment, or `nil` to inherit the gate's.
        public let environment: [String: String]?
        /// The budget the run is given.
        public let budget: CheckerBudget.Allowance

        /// Creates a request.
        public init(
            checkerId: String,
            executable: String,
            arguments: [String],
            directory: String?,
            environment: [String: String]?,
            budget: CheckerBudget.Allowance
        ) {
            self.checkerId = checkerId
            self.executable = executable
            self.arguments = arguments
            self.directory = directory
            self.environment = environment
            self.budget = budget
        }

        /// The command as a person would type it: the executable's name, then its arguments.
        public var command: String {
            ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
                .joined(separator: " ")
        }
    }

    /// What the process starter is handed.
    public struct Invocation: Sendable {
        /// Absolute path of the executable.
        public let executable: String
        /// Its arguments.
        public let arguments: [String]
        /// Working directory, or `nil` to inherit.
        public let directory: String?
        /// The complete environment, or `nil` to inherit.
        public let environment: [String: String]?
        /// The wall-clock budget, in seconds.
        public let timeout: TimeInterval
    }

    /// What the process starter answers with.
    public struct Output: Sendable, Equatable {
        /// Standard output.
        public let stdout: String
        /// Standard error.
        public let stderr: String
        /// The exit code.
        public let exitCode: Int32

        /// Creates an output.
        public init(stdout: String, stderr: String, exitCode: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    private let launch: @Sendable (Invocation) throws -> Output
    private let monotonicSeconds: @Sendable () -> TimeInterval
    private let load: @Sendable () -> MachineLoad?

    /// Creates a launcher.
    ///
    /// - Parameters:
    ///   - launch: Starts the process and waits for it, within the invocation's timeout.
    ///   - monotonicSeconds: A clock that only moves forward; read before and after the run.
    ///   - load: Reads the machine's load; called once, when the run has ended.
    public init(
        launch: @escaping @Sendable (Invocation) throws -> Output,
        monotonicSeconds: @escaping @Sendable () -> TimeInterval,
        load: @escaping @Sendable () -> MachineLoad?
    ) {
        self.launch = launch
        self.monotonicSeconds = monotonicSeconds
        self.load = load
    }

    /// The launcher the gate runs with: the process kernel, system uptime, `getloadavg`.
    public static let live = ToolLauncher(
        launch: { invocation in
            // SAFETY: every caller is a checker passing a hardcoded system tool path
            let result = try ProcessRunner.run(
                invocation.executable,
                arguments: invocation.arguments,
                currentDirectory: invocation.directory,
                environment: invocation.environment,
                timeout: invocation.timeout)
            return Output(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        },
        monotonicSeconds: { ProcessInfo.processInfo.systemUptime },
        load: { MachineLoad.current() })

    /// Runs `request` and records the outcome.
    ///
    /// - Parameter request: What to run, and the budget to run it under.
    /// - Returns: The run, whether it finished, failed or was stopped at its budget.
    /// - Throws: Whatever the process starter throws — the executable could not be started,
    ///   or the process kernel refused a budget that is not a finite number.
    public func run(_ request: Request) throws -> ToolRun {
        let started = monotonicSeconds()
        let output = try launch(Invocation(
            executable: request.executable,
            arguments: request.arguments,
            directory: request.directory,
            environment: request.environment,
            timeout: request.budget.seconds))
        let elapsed = max(0, monotonicSeconds() - started)
        return ToolRun(
            checkerId: request.checkerId,
            command: request.command,
            directory: request.directory,
            stdout: output.stdout,
            stderr: output.stderr,
            exitCode: output.exitCode,
            budget: request.budget,
            elapsed: elapsed,
            load: load())
    }
}
