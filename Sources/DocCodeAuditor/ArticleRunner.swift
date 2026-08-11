import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// How one assembled article's process ended, and what it wrote.
public struct RunOutcome: Sendable, Codable, Equatable {

    /// The way the process stopped.
    ///
    /// The distinctions matter because the repairs are different. A signal is a defect in the
    /// documented code; a timeout is a hang the typechecker could never have seen; a build
    /// failure is rung 1's business and must not be counted twice.
    public enum Termination: Sendable, Codable, Equatable {

        /// The process ran to completion with this status.
        case exited(Int32)

        /// The process was killed by this signal.
        case signalled(Int32)

        /// The process was still running at the deadline and was killed.
        case timedOut

        /// The program never ran, because it could not be compiled or linked.
        case buildFailed(String)

        /// Whether this is the one termination a passing article may have.
        ///
        /// Deliberately narrow. "Exited 0" is the whole of success; everything else — a
        /// non-zero status, a signal, a deadline — is a finding with its own name.
        public var isSuccess: Bool { self == .exited(0) }

        /// A one-line description a reader does not have to look up.
        ///
        /// `139` in a log is a number; `SIGSEGV` is a sentence. The table covers the signals
        /// a documentation example actually dies of, and an unrecognised signal still
        /// reports its number rather than vanishing into "failed".
        public var summary: String {
            switch self {
            case .exited(let status):
                return status == 0 ? "exited 0" : "exited \(status)"
            case .signalled(let signal):
                return "killed by \(Self.signalName(signal))"
            case .timedOut:
                return "still running at the deadline"
            case .buildFailed(let reason):
                return "did not build: \(reason)"
            }
        }

        /// The mnemonic for a signal number, or the number itself when it is not one of the
        /// handful a documentation example dies of.
        static func signalName(_ signal: Int32) -> String {
            let names: [Int32: String] = [
                2: "SIGINT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
                8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE"
            ]
            guard let name = names[signal] else { return "signal \(signal)" }
            return "\(name) (\(signal))"
        }
    }

    /// How the process ended.
    public let termination: Termination

    /// Everything the program wrote to stdout.
    public let standardOutput: String

    /// Everything the program wrote to stderr, with any injected claim records removed.
    ///
    /// Retained even on success. `1.3-TimeValueOfMoney` prints deliberate error text from a
    /// `catch` block, so stderr is *evidence*, never the verdict — the exit status is the
    /// verdict.
    public let standardError: String

    /// Creates an outcome.
    public init(termination: Termination, standardOutput: String, standardError: String) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Whether two runs of the same program agreed, and by how much.
///
/// An unseeded example has no pinned output: rung 3 cannot verify it, and neither rung can
/// honestly call itself hermetic over it. Detection is one extra run and a comparison.
///
/// The magnitude is part of the report because it names the repair. "228 of 232 lines
/// differ" says the article samples an unseeded generator throughout; "1 of 232" says one
/// clock reading leaked into an otherwise pinned program, which is a different day's work.
public struct DeterminismReport: Sendable, Codable, Equatable {

    /// How many output lines differed between the two runs.
    public let differingLines: Int

    /// How many lines the longer of the two runs produced.
    public let totalLines: Int

    /// Whether the two runs agreed byte for byte.
    public var isDeterministic: Bool { differingLines == 0 }

    /// Creates a report.
    public init(differingLines: Int, totalLines: Int) {
        self.differingLines = differingLines
        self.totalLines = totalLines
    }

    /// Compares two runs' output line by line.
    ///
    /// A length difference counts as a difference: a program that printed nine lines once
    /// and ten the next is not deterministic, and comparing only the overlap would call it
    /// so.
    ///
    /// - Parameters:
    ///   - first: stdout of the first run.
    ///   - second: stdout of the second run.
    /// - Returns: The differing-line count against the longer run's length.
    public static func comparing(_ first: String, _ second: String) -> DeterminismReport {
        let left = outputLines(first)
        let right = outputLines(second)
        let total = max(left.count, right.count)
        var differing = 0
        for index in 0..<total {
            let a = index < left.count ? left[index] : nil
            let b = index < right.count ? right[index] : nil
            if a != b { differing += 1 }
        }
        return DeterminismReport(differingLines: differing, totalLines: total)
    }

    /// The lines a program actually printed.
    ///
    /// A stream ending in a newline is not a stream with a trailing blank line on it — a
    /// program that prints three lines prints three, and counting the terminator as a fourth
    /// would put an off-by-one into every reported total. Only *one* trailing empty is
    /// dropped, so a program that deliberately ends with a blank line still reports it.
    static func outputLines(_ stream: String) -> [String] {
        var lines = stream.lines
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

/// What running one article established.
public struct RunVerdict: Sendable, Codable {

    /// Path of the article that was run.
    public let articlePath: String

    /// How its process ended, and what it wrote.
    public let outcome: RunOutcome

    /// The determinism comparison, or `nil` when it was not attempted — because the program
    /// never ran, or because the caller turned the second run off.
    public let determinism: DeterminismReport?

    /// Whether the article ran cleanly *and* reproducibly.
    ///
    /// Both halves are required. An article that exits 0 with different numbers every time
    /// has not been verified by anything; passing it would certify the opposite of what was
    /// measured.
    public var passed: Bool {
        outcome.termination.isSuccess && (determinism?.isDeterministic ?? true)
    }

    /// Creates a verdict.
    public init(articlePath: String, outcome: RunOutcome, determinism: DeterminismReport?) {
        self.articlePath = articlePath
        self.outcome = outcome
        self.determinism = determinism
    }
}

/// Everything the runner needs beyond what the typechecker already needed.
public struct DocRunOptions: Sendable {

    /// Module search path, imports and compiler flags — shared with rung 1, so an article
    /// is executed under exactly the flags it was typechecked under.
    public var audit: DocCodeAuditOptions

    /// Directories offered to the linker as `-L`.
    public var librarySearchPaths: [String]

    /// How long a single run may take before it is killed.
    ///
    /// The measured maximum across one 73-article catalogue was 0.40s, so the default is
    /// roughly 75× headroom — wide enough that a slow machine never trips it, and narrow
    /// enough that a runaway article costs 30 seconds rather than a whole CI job.
    public var timeout: Duration

    /// The locale identifier the program is run under.
    ///
    /// Measured: the same program prints `2,000` under `en_US` and `2.000` under `de_DE`,
    /// and on macOS `LANG` does not move Foundation's locale — only `-AppleLocale` on the
    /// argv does. Without pinning it, every documented figure is a check on the gate
    /// machine's System Settings.
    public var locale: String

    /// Whether to run each article twice and compare.
    public var verifiesDeterminism: Bool

    /// Creates options; every knob defaults to the documented value.
    public init(
        audit: DocCodeAuditOptions = DocCodeAuditOptions(),
        librarySearchPaths: [String] = [],
        timeout: Duration = .seconds(30),
        locale: String = "en_US",
        verifiesDeterminism: Bool = true
    ) {
        self.audit = audit
        self.librarySearchPaths = librarySearchPaths
        self.timeout = timeout
        self.locale = locale
        self.verifiesDeterminism = verifiesDeterminism
    }
}

/// Compiles, links and executes one article.
///
/// Rung 2 of the verification ladder. Rung 1 asks whether the code a reader would copy
/// *builds*; this asks whether it *runs*. The gap between the two is not theoretical: on
/// one 73-article catalogue, three articles typechecked cleanly and then trapped, segfaulted
/// or failed to load — including the flagship worked example of a guide about scenario
/// analysis, which force-unwraps a dictionary key it never sets.
///
/// ## Isolation
///
/// Each run gets its own `NSTemporaryDirectory()` directory, holding the assembled source,
/// the linked executable and the captured streams. Nothing is written to the package's
/// build tree, so any number of articles can run at once.
///
/// ## The trust boundary
///
/// This executes arbitrary code from the repository — which is a boundary the gate already
/// crosses twice, since `swift build` executes the manifest and `swift test` executes tests.
/// What a documentation runner *adds* is the possibility of a hang, and the timeout is the
/// answer to that: killed at the deadline and reported as `doc-run.timeout`, never as a pass.
public enum ArticleRunner {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocRunAuditor")

    /// Assembles, builds and runs one article.
    ///
    /// - Parameters:
    ///   - article: The `.md` file.
    ///   - options: Compiler flags, link paths, timeout and locale.
    /// - Returns: The verdict, including the captured streams even on success.
    /// - Throws: If the article cannot be read or the work directory cannot be created.
    public static func run(article: URL, options: DocRunOptions) throws -> RunVerdict {
        let text = try String(contentsOf: article, encoding: .utf8)
        let assembled = ArticleAssembler.assemble(text, imports: options.audit.imports)
        return try run(assembled: assembled, articlePath: article.path, options: options).verdict
    }

    /// Builds and runs an already-assembled article.
    ///
    /// Split from ``run(article:options:)`` so `doc-claims` can inject its assertions into
    /// the assembled program first and still execute it through exactly this path — one
    /// runner, one set of flags, one timeout policy.
    ///
    /// - Parameters:
    ///   - assembled: The program to run.
    ///   - articlePath: The article it came from, for the verdict.
    ///   - options: Compiler flags, link paths, timeout and locale.
    /// - Returns: The verdict and any claim records the injected assertions emitted.
    /// - Throws: If the work directory cannot be created or the source cannot be written.
    static func run(
        assembled: AssembledArticle, articlePath: String, options: DocRunOptions
    ) throws -> (verdict: RunVerdict, records: [ClaimRecord]) {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let source = work.appendingPathComponent("main.swift")
        try assembled.source.write(to: source, atomically: true, encoding: .utf8)

        let executable = work.appendingPathComponent("article")
        if let failure = build(source: source, executable: executable, options: options) {
            return (
                RunVerdict(
                    articlePath: articlePath,
                    outcome: RunOutcome(
                        termination: .buildFailed(failure), standardOutput: "", standardError: ""),
                    determinism: nil),
                [])
        }

        let first = execute(executable, in: work, options: options)
        var determinism: DeterminismReport?
        if options.verifiesDeterminism, first.outcome.termination.isSuccess {
            let second = execute(executable, in: work, options: options)
            determinism = DeterminismReport.comparing(
                first.outcome.standardOutput, second.outcome.standardOutput)
        }

        return (
            RunVerdict(articlePath: articlePath, outcome: first.outcome, determinism: determinism),
            first.records)
    }

    // MARK: - Build

    /// Compiles and links the assembled program, returning `nil` on success or the first
    /// error on failure.
    ///
    /// Deliberately reduced to one line. A build failure here is rung 1's finding, already
    /// reported in full by `doc-code`; repeating the whole diagnostic wall would double-count
    /// every article that does not compile and bury the ones that compile and die.
    static func build(source: URL, executable: URL, options: DocRunOptions) -> String? {
        var arguments = ["swiftc", source.path, "-o", executable.path, "-diagnostic-style=llvm"]
        if let moduleSearchPath = options.audit.moduleSearchPath {
            arguments += ["-I", moduleSearchPath]
        }
        for path in options.audit.headerSearchPaths {
            arguments += ["-Xcc", "-I\(path)"]
        }
        for path in options.audit.moduleMapFiles {
            arguments += ["-Xcc", "-fmodule-map-file=\(path)"]
        }
        arguments += options.audit.toolchainFlags
        arguments += options.audit.languageFlags
        arguments += linkArguments(
            imports: options.audit.imports,
            searchPaths: librarySearchPaths(options: options),
            source: (try? String(contentsOf: source, encoding: .utf8)) ?? "")

        let output = capture(arguments: arguments)
        guard output.status != 0 else { return nil }
        let firstError = output.text.lines
            .first { $0.contains(": error: ") }
            .flatMap { line in line.range(of: ": error: ").map { String(line[$0.upperBound...]) } }
        return firstError ?? "swiftc exited \(output.status) without a located error"
    }

    /// Library search paths, defaulting to the module search path when none was configured.
    ///
    /// A package's `.build/debug` holds both the `.swiftmodule` the typechecker reads and the
    /// `lib<Module>.a` the linker needs, so the one path already known is almost always the
    /// right answer and asking for it twice is a knob nobody would set correctly.
    static func librarySearchPaths(options: DocRunOptions) -> [String] {
        if !options.librarySearchPaths.isEmpty { return options.librarySearchPaths }
        return options.audit.moduleSearchPath.map { [$0] } ?? []
    }

    /// Linker arguments: the search paths, the libraries behind the article's imports, and
    /// the testing runtime when the article needs it.
    ///
    /// Libraries are derived from the imports rather than configured, because the import
    /// list is already the authoritative statement of what the article depends on. A module
    /// with no static archive beside it — a system framework, a header-only shim — simply
    /// contributes no `-l`, which is the correct answer rather than a link error.
    static func linkArguments(
        imports: [String], searchPaths: [String], source: String
    ) -> [String] {
        var arguments: [String] = []
        for path in searchPaths {
            arguments += ["-L", path]
        }

        let manager = FileManager.default
        for module in imports where module != "Foundation" {
            let found = searchPaths.contains { path in
                ["a", "dylib", "tbd"].contains { suffix in
                    // SAFETY: CLI tool looks for the project's own built library
                    manager.fileExists(atPath: path + "/lib\(module).\(suffix)")
                }
            }
            if found { arguments.append("-l\(module)") }
        }

        // Rung 1 solved `import Testing` at the typecheck step with `-F` and `-plugin-path`.
        // At the link step the same block dies with `Library not loaded:
        // @rpath/Testing.framework`, and the natural response — marking the block
        // illustrative — would be the gate manufacturing an exemption for a construct it
        // could not launch rather than one the author meant as a fragment.
        if importsTesting(source), let frameworks = Toolchain.platformFrameworkPath() {
            arguments += ["-Xlinker", "-rpath", "-Xlinker", frameworks]
        }
        return arguments
    }

    /// Whether the program imports swift-testing, and so needs its framework at run time.
    ///
    /// Matched on the import *statement* rather than on the word, so a `let testing = 1` or a
    /// commented-out import does not drag an rpath in — and, more importantly, so an article
    /// that genuinely imports it is never missed and quietly exempted.
    static func importsTesting(_ source: String) -> Bool {
        source.lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("import ") else { return false }
            return trimmed.dropFirst("import ".count)
                .trimmingCharacters(in: .whitespaces) == "Testing"
        }
    }

    // MARK: - Execute

    /// Runs the linked executable with a wall-clock deadline, capturing both streams.
    ///
    /// Streams go to *files* rather than pipes. A pipe whose reader is blocked on
    /// `waitUntilExit` deadlocks the moment the child fills the buffer, and one article in
    /// the measured corpus prints 192 lines — so the shape that works on a small example is
    /// exactly the shape that hangs on a real one.
    static func execute(
        _ executable: URL, in work: URL, options: DocRunOptions
    ) -> (outcome: RunOutcome, records: [ClaimRecord]) {
        let outPath = work.appendingPathComponent("stdout.txt")
        let errPath = work.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outPath.path, contents: nil)
        FileManager.default.createFile(atPath: errPath.path, contents: nil)

        guard let out = try? FileHandle(forWritingTo: outPath),
              let err = try? FileHandle(forWritingTo: errPath) else {
            return (
                RunOutcome(
                    termination: .buildFailed("could not open the capture files"),
                    standardOutput: "", standardError: ""),
                [])
        }
        defer {
            try? out.close()
            try? err.close()
        }

        let process = Process()
        // SAFETY: subprocess runs the executable this checker just linked in its own
        // temporary directory, from the article under audit
        process.executableURL = executable
        process.arguments = ["-AppleLocale", options.locale, "-AppleLanguages", "(en)"]
        process.currentDirectoryURL = work
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let termination: RunOutcome.Termination
        do {
            try process.run()
            termination = wait(for: process, timeout: options.timeout)
        } catch {
            logger.error("Could not launch the assembled article: \(error.localizedDescription, privacy: .public)")
            termination = .buildFailed("could not launch: \(error.localizedDescription)")
        }

        let stdout = (try? String(contentsOf: outPath, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errPath, encoding: .utf8)) ?? ""
        return (
            RunOutcome(
                termination: termination,
                standardOutput: stdout,
                standardError: ClaimRecord.stripping(stderr)),
            ClaimRecord.parse(stderr))
    }

    /// Waits for `process`, killing it at the deadline.
    ///
    /// Polls rather than blocking, because `waitUntilExit()` has no deadline and a
    /// documentation example that loops forever would otherwise hold the gate open until
    /// somebody noticed. `SIGKILL` rather than `terminate()`: a program that traps its way
    /// into a spin is not going to honour a polite request.
    static func wait(for process: Process, timeout: Duration) -> RunOutcome.Termination {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return .timedOut
        }
        process.waitUntilExit()
        return process.terminationReason == .uncaughtSignal
            ? .signalled(process.terminationStatus)
            : .exited(process.terminationStatus)
    }

    /// Runs `xcrun` with `arguments`, returning its combined output and status.
    static func capture(arguments: [String]) -> (status: Int32, text: String) {
        let process = Process()
        let pipe = Pipe()
        // SAFETY: subprocess with `/usr/bin/xcrun swiftc` over a file this checker just
        // wrote into its own temporary directory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            logger.error("Could not run swiftc: \(error.localizedDescription, privacy: .public)")
            return (1, "error: could not run swiftc: \(error.localizedDescription)")
        }
    }
}
