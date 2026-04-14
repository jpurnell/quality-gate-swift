import Foundation
import QualityGateCore

/// Lints DocC documentation for errors and warnings.
///
/// Runs `swift package generate-documentation` and parses the output
/// for documentation issues such as unresolved symbol references,
/// invalid markdown, and missing documentation.
///
/// ## Usage
///
/// ```swift
/// let linter = DocLinter()
/// let result = try await linter.check(configuration: config)
/// ```
public struct DocLinter: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "doc-lint"

    /// Human-readable name for this checker.
    public let name = "Documentation Linter"

    /// Creates a new DocLinter instance.
    public init() {}

    /// Run the documentation linter.
    ///
    /// Executes `swift package generate-documentation` and parses any diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        // Build the command arguments
        var arguments = ["package", "generate-documentation"]
        arguments.append(contentsOf: docArguments(for: configuration))

        // Run swift package generate-documentation
        let process = Process() // SAFETY: runs swift package generate-documentation to lint DocC coverage
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            let duration = ContinuousClock.now - startTime
            return CheckResult(
                checkerId: id,
                status: .failed,
                diagnostics: [
                    Diagnostic(
                        severity: .error,
                        message: "Failed to run documentation generator: \(error.localizedDescription)",
                        ruleId: "doc-lint-execution"
                    )
                ],
                duration: duration
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        let combinedOutput = output + "\n" + errorOutput

        let duration = ContinuousClock.now - startTime
        let exitCode = process.terminationStatus

        return Self.createResult(output: combinedOutput, exitCode: exitCode, duration: duration)
    }

    /// Generates command-line arguments for the documentation generator.
    ///
    /// - Parameter configuration: The project configuration.
    /// - Returns: Array of arguments to pass to `swift package generate-documentation`.
    public func docArguments(for configuration: Configuration) -> [String] {
        var args: [String] = []

        if let target = configuration.docTarget {
            args.append("--target")
            args.append(target)
        }

        return args
    }

    /// Parses DocC output for diagnostic messages.
    ///
    /// Recognizes formats like:
    /// - `warning: Symbol 'foo' is undocumented`
    /// - `error: Unable to resolve topic reference`
    /// - `/path/to/file.swift:10:5: warning: No documentation`
    ///
    /// - Parameter output: The combined stdout/stderr output from the documentation generator.
    /// - Returns: Array of parsed diagnostics.
    public static func parseDocCOutput(_ output: String) -> [Diagnostic] {
        guard !output.isEmpty else { return [] }

        var diagnostics: [Diagnostic] = []
        let lines = output.components(separatedBy: .newlines)

        // Pattern for file:line:column: severity: message
        // Example: /path/to/Sources/Module/File.swift:10:5: warning: No documentation for 'myFunc'
        let fileLocationPattern = #"^(.+?):(\d+):(\d+):\s*(warning|error|note):\s*(.+)$"#
        let fileLocationRegex = try? NSRegularExpression(pattern: fileLocationPattern, options: [])

        // Pattern for simple severity: message
        // Example: warning: 'MyType' doesn't exist at '/MyModule/MyType'
        let simplePattern = #"^(warning|error|note):\s*(.+)$"#
        let simpleRegex = try? NSRegularExpression(pattern: simplePattern, options: [])

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and progress messages
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("[") { continue }  // [1/10] Compiling...
            if trimmed.hasPrefix("Building") { continue }
            if trimmed.hasPrefix("Build complete") { continue }
            if trimmed.hasPrefix("Finished building") { continue }
            if trimmed.hasPrefix("Compiling") { continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)

            // Try file:line:column pattern first
            if let fileLocationRegex = fileLocationRegex,
               let match = fileLocationRegex.firstMatch(in: trimmed, options: [], range: range) {

                let filePath = extractGroup(match, group: 1, from: trimmed)
                let lineNum = Int(extractGroup(match, group: 2, from: trimmed)) ?? 0
                let colNum = Int(extractGroup(match, group: 3, from: trimmed)) ?? 0
                let severityStr = extractGroup(match, group: 4, from: trimmed)
                let message = extractGroup(match, group: 5, from: trimmed)

                let severity = parseSeverity(severityStr)

                diagnostics.append(Diagnostic(
                    severity: severity,
                    message: message,
                    file: filePath,
                    line: lineNum,
                    column: colNum,
                    ruleId: "docc"
                ))
                continue
            }

            // Try simple severity: message pattern
            if let simpleRegex = simpleRegex,
               let match = simpleRegex.firstMatch(in: trimmed, options: [], range: range) {

                let severityStr = extractGroup(match, group: 1, from: trimmed)
                let message = extractGroup(match, group: 2, from: trimmed)

                let severity = parseSeverity(severityStr)

                diagnostics.append(Diagnostic(
                    severity: severity,
                    message: message,
                    ruleId: "docc"
                ))
            }
        }

        return diagnostics
    }

    /// Creates a CheckResult from documentation generator output.
    ///
    /// - Parameters:
    ///   - output: The combined stdout/stderr output.
    ///   - exitCode: The process exit code.
    ///   - duration: How long the check took.
    /// - Returns: A CheckResult with appropriate status and diagnostics.
    public static func createResult(
        output: String,
        exitCode: Int32,
        duration: Duration
    ) -> CheckResult {
        let diagnostics = parseDocCOutput(output)

        // Failed if exit code non-zero OR any errors found
        let hasErrors = diagnostics.contains { $0.severity == .error }
        let status: CheckResult.Status = (exitCode != 0 || hasErrors) ? .failed : .passed

        return CheckResult(
            checkerId: "doc-lint",
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Private Helpers

    private static func extractGroup(
        _ match: NSTextCheckingResult,
        group: Int,
        from string: String
    ) -> String {
        guard let range = Range(match.range(at: group), in: string) else {
            return ""
        }
        return String(string[range])
    }

    private static func parseSeverity(_ string: String) -> Diagnostic.Severity {
        switch string.lowercased() {
        case "error":
            return .error
        case "warning":
            return .warning
        case "note":
            return .note
        default:
            return .warning
        }
    }
}
