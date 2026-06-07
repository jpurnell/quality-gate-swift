import Foundation
import os
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
    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocLinter")

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

        let projectRoot = FileManager.default.currentDirectoryPath
        let packagePath = (projectRoot as NSString).appendingPathComponent("Package.swift")

        guard FileManager.default.fileExists(atPath: packagePath) else { // SAFETY: CLI reads Package.swift from cwd; no user-supplied path component
            let duration = ContinuousClock.now - startTime
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No Package.swift found; skipping documentation lint.",
                        ruleId: "doc-lint-skip"
                    )
                ],
                duration: duration
            )
        }

        // Build the command arguments
        var arguments = ["package", "generate-documentation"]

        let packageContent: String
        do {
            packageContent = try String(contentsOfFile: packagePath, encoding: .utf8)
        } catch {
            Self.logger.warning("Failed to read Package.swift: \(error.localizedDescription, privacy: .public)")
            packageContent = ""
        }

        if let target = Self.resolveDocTarget(
            configured: configuration.docTarget,
            packageContent: packageContent
        ) {
            arguments.append("--target")
            arguments.append(target)
        }

        // Run swift package generate-documentation
        // SAFETY: runs swift package generate-documentation to lint DocC coverage
        let result: ProcessRunner.Output
        do {
            result = try ProcessRunner.run(
                "/usr/bin/swift",
                arguments: arguments,
                currentDirectory: FileManager.default.currentDirectoryPath
            )
        } catch {
            Self.logger.error("Failed to run documentation generator: \(error.localizedDescription, privacy: .public)")
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

        let combinedOutput = result.stdout + "\n" + result.stderr

        let duration = ContinuousClock.now - startTime
        let exitCode = result.exitCode

        let baseResult = Self.createResult(output: combinedOutput, exitCode: exitCode, duration: duration)
        let enrichedDiagnostics = Self.enrichDiagnosticsWithLocations(
            baseResult.diagnostics,
            sourceRoot: projectRoot
        )
        return CheckResult(
            checkerId: id,
            status: baseResult.status,
            diagnostics: enrichedDiagnostics,
            duration: duration
        )
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
        let fileLocationRegex: NSRegularExpression?
        do {
            fileLocationRegex = try NSRegularExpression(pattern: fileLocationPattern, options: [])
        } catch {
            logger.warning("Failed to compile file-location regex: \(error.localizedDescription, privacy: .public)")
            fileLocationRegex = nil
        }

        // Pattern for simple severity: message
        // Example: warning: 'MyType' doesn't exist at '/MyModule/MyType'
        let simplePattern = #"^(warning|error|note):\s*(.+)$"#
        let simpleRegex: NSRegularExpression?
        do {
            simpleRegex = try NSRegularExpression(pattern: simplePattern, options: [])
        } catch {
            logger.warning("Failed to compile simple-severity regex: \(error.localizedDescription, privacy: .public)")
            simpleRegex = nil
        }

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
                    filePath: filePath,
                    lineNumber: lineNum,
                    columnNumber: colNum,
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

    // MARK: - Target Auto-Detection

    /// Parses the first library product's target from Package.swift content.
    ///
    /// - Parameter packageContent: The raw text of a Package.swift file.
    /// - Returns: The first target name from the first `.library` product, or nil.
    public static func parseLibraryTarget(from packageContent: String) -> String? {
        guard !packageContent.isEmpty else { return nil }
        let pattern = #"\.library\s*\([\s\S]*?targets:\s*\[\s*"([^"]+)""#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators]
            )
        } catch {
            logger.warning("Failed to compile library-target regex: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let range = NSRange(packageContent.startIndex..., in: packageContent)
        guard let match = regex.firstMatch(in: packageContent, range: range),
              let targetRange = Range(match.range(at: 1), in: packageContent) else {
            return nil
        }
        return String(packageContent[targetRange])
    }

    /// Resolves the documentation target, preferring explicit config over auto-detection.
    ///
    /// - Parameters:
    ///   - configured: The explicitly configured `docTarget`, if any.
    ///   - packageContent: The raw text of Package.swift for auto-detection fallback.
    /// - Returns: The resolved target name, or nil if neither source provides one.
    public static func resolveDocTarget(
        configured: String?,
        packageContent: String
    ) -> String? {
        configured ?? parseLibraryTarget(from: packageContent)
    }

    // MARK: - Diagnostic Location Enrichment

    struct SourceLocation: Sendable {
        let filePath: String
        let lineNumber: Int
    }

    /// A parsed symbol reference from a DocC "doesn't exist" warning.
    public struct SymbolReference: Sendable, Equatable {
        /// The symbol name that couldn't be resolved.
        public let symbol: String
        /// The DocC path context where the reference was found.
        public let contextPath: String
    }

    /// Enriches diagnostics that lack file/line info by searching source files.
    ///
    /// For "missing documentation" warnings, finds the parameter in function signatures.
    /// For "not found" warnings, finds the parameter in doc comments.
    ///
    /// - Parameters:
    ///   - diagnostics: The parsed diagnostics, some of which may lack location info.
    ///   - sourceRoot: The project root directory containing a Sources/ folder.
    /// - Returns: Diagnostics with file/line info added where possible.
    public static func enrichDiagnosticsWithLocations(
        _ diagnostics: [Diagnostic],
        sourceRoot: String
    ) -> [Diagnostic] {
        let rootURL = URL(fileURLWithPath: sourceRoot).standardized
        let sourcesURL = rootURL.appendingPathComponent("Sources").standardized
        guard sourcesURL.path.hasPrefix(rootURL.path) else { return diagnostics } // SAFETY: reject path traversal
        guard FileManager.default.fileExists(atPath: sourcesURL.path) else { return diagnostics } // SAFETY: validated child of sourceRoot

        let needsEnrichment = diagnostics.contains { $0.filePath == nil }
        guard needsEnrichment else { return diagnostics }

        let swiftFiles = findSwiftSourceFiles(under: sourcesURL.path)
        guard !swiftFiles.isEmpty else { return diagnostics }

        var result = diagnostics

        enrichParameterDiagnostics(&result, swiftFiles: swiftFiles)
        enrichSymbolReferenceDiagnostics(&result, sourcesPath: sourcesURL.path, allFiles: swiftFiles)

        return result
    }

    private static func enrichParameterDiagnostics(
        _ diagnostics: inout [Diagnostic],
        swiftFiles: [String]
    ) {
        var paramDiagIndices: [String: [(index: Int, isNotFound: Bool)]] = [:]
        for (index, diag) in diagnostics.enumerated() {
            guard diag.filePath == nil,
                  let paramName = extractParameterName(from: diag.message) else { continue }
            let isNotFound = diag.message.contains("not found")
            paramDiagIndices[paramName, default: []].append((index, isNotFound))
        }
        guard !paramDiagIndices.isEmpty else { return }

        let onlySwift = swiftFiles.filter { $0.hasSuffix(".swift") }
        for (paramName, entries) in paramDiagIndices {
            let sigLocations = findParameterInSignatures(paramName, files: onlySwift)
            let docLocations = findParameterInDocComments(paramName, files: onlySwift)

            for (i, entry) in entries.enumerated() {
                let locations = entry.isNotFound ? docLocations : sigLocations
                guard let loc = i < locations.count ? locations[i] : locations.last else { continue }
                diagnostics[entry.index] = withLocation(diagnostics[entry.index], from: loc)
            }
        }
    }

    private static func enrichSymbolReferenceDiagnostics(
        _ diagnostics: inout [Diagnostic],
        sourcesPath: String,
        allFiles: [String]
    ) {
        for (index, diag) in diagnostics.enumerated() {
            guard diag.filePath == nil,
                  let ref = extractSymbolReference(from: diag.message) else { continue }

            let candidates = narrowFilesForContext(
                ref.contextPath, sourcesPath: sourcesPath, allFiles: allFiles
            )
            let locations = findSymbolNearContext(
                ref.symbol, contextPath: ref.contextPath, files: candidates
            )
            guard let loc = locations.first else { continue }
            diagnostics[index] = withLocation(diagnostics[index], from: loc)
        }
    }

    private static func findSymbolNearContext(
        _ symbol: String,
        contextPath: String,
        files: [String]
    ) -> [SourceLocation] {
        let components = contextPath.split(separator: "/").map(String.init)

        guard components.count >= 3 else {
            return findSymbolInDocComments(symbol, files: files)
        }

        let methodBaseName = String(components[2].prefix(while: { $0 != "(" }))
        var locations: [SourceLocation] = []

        for file in files {
            let content: String
            do {
                content = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                logger.warning("Skipping unreadable file \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let lines = content.components(separatedBy: .newlines)

            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("func \(methodBaseName)") else { continue }

                var docLine = lineIndex - 1
                while docLine >= 0 {
                    let docTrimmed = lines[docLine].trimmingCharacters(in: .whitespaces)
                    guard docTrimmed.hasPrefix("///") || docTrimmed.hasPrefix("*") || docTrimmed.isEmpty else { break }
                    if lineContainsSymbolRef(docTrimmed, symbol: symbol) {
                        locations.append(SourceLocation(filePath: file, lineNumber: docLine + 1))
                    }
                    docLine -= 1
                }
            }
        }

        return locations.isEmpty ? findSymbolInDocComments(symbol, files: files) : locations
    }

    private static func withLocation(_ diagnostic: Diagnostic, from loc: SourceLocation) -> Diagnostic {
        Diagnostic(
            severity: diagnostic.severity,
            message: diagnostic.message,
            filePath: loc.filePath,
            lineNumber: loc.lineNumber,
            ruleId: diagnostic.ruleId,
            suggestedFix: diagnostic.suggestedFix
        )
    }

    private static func narrowFilesForContext(
        _ contextPath: String,
        sourcesPath: String,
        allFiles: [String]
    ) -> [String] {
        let components = contextPath.split(separator: "/").map(String.init)
        guard let moduleName = components.first else { return allFiles }

        let moduleDir = (sourcesPath as NSString).appendingPathComponent(moduleName)
        let moduleFiles = allFiles.filter { $0.hasPrefix(moduleDir) }
        guard !moduleFiles.isEmpty else { return allFiles }

        if components.count >= 2 {
            let typeName = String(components[1].prefix(while: { $0 != "(" }))
            let preferred = moduleFiles.filter {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent == typeName
            }
            if !preferred.isEmpty { return preferred }
        }

        return moduleFiles
    }

    private static func findSymbolInDocComments(
        _ symbol: String,
        files: [String]
    ) -> [SourceLocation] {
        var locations: [SourceLocation] = []

        for file in files {
            let content: String
            do {
                content = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                logger.warning("Skipping unreadable file \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let lines = content.components(separatedBy: .newlines)
            let isMarkdown = file.hasSuffix(".md")

            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isDocLine = isMarkdown || trimmed.hasPrefix("///") || trimmed.hasPrefix("*")
                guard isDocLine else { continue }
                if lineContainsSymbolRef(trimmed, symbol: symbol) {
                    locations.append(SourceLocation(filePath: file, lineNumber: lineIndex + 1))
                }
            }
        }

        return locations
    }

    private static func lineContainsSymbolRef(_ line: String, symbol: String) -> Bool {
        line.contains("``\(symbol)``") || line.contains("``\(symbol)/")
            || line.contains("`\(symbol)`") || line.contains("`\(symbol)/")
    }

    /// Extracts a parameter name from a DocC diagnostic message.
    ///
    /// - Parameter message: The diagnostic message text.
    /// - Returns: The parameter name, or nil if the message doesn't reference a parameter.
    public static func extractParameterName(from message: String) -> String? {
        let pattern = #"Parameter '(\w+)'"#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            logger.warning("Failed to compile parameter-name regex: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let nameRange = Range(match.range(at: 1), in: message) else {
            return nil
        }
        return String(message[nameRange])
    }

    /// Extracts a symbol reference from a DocC "doesn't exist" warning.
    ///
    /// - Parameter message: The diagnostic message text.
    /// - Returns: The symbol name and context path, or nil.
    public static func extractSymbolReference(from message: String) -> SymbolReference? {
        let pattern = #"'(\w+)' doesn't exist at '(/[^']+)'"#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            logger.warning("Failed to compile symbol-reference regex: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let symbolRange = Range(match.range(at: 1), in: message),
              let pathRange = Range(match.range(at: 2), in: message) else {
            return nil
        }
        return SymbolReference(
            symbol: String(message[symbolRange]),
            contextPath: String(message[pathRange])
        )
    }

    private static let docFileExtensions: Set<String> = ["swift", "md"]

    private static func findSwiftSourceFiles(under directory: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        for case let url as URL in enumerator where docFileExtensions.contains(url.pathExtension) {
            files.append(url.path)
        }
        return files.sorted()
    }

    private static func findParameterInSignatures(
        _ paramName: String,
        files: [String]
    ) -> [SourceLocation] {
        let escapedName = NSRegularExpression.escapedPattern(for: paramName)
        let paramPattern = #"(?:^|[(,])\s*"# + escapedName + #"\s*:"#
        let paramRegex: NSRegularExpression
        do {
            paramRegex = try NSRegularExpression(pattern: paramPattern)
        } catch {
            logger.warning("Failed to compile parameter regex: \(error.localizedDescription, privacy: .public)")
            return []
        }

        return files.flatMap { file -> [SourceLocation] in
            let content: String
            do {
                content = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                logger.warning("Skipping unreadable file \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return []
            }
            return scanFileForParameter(content, file: file, paramRegex: paramRegex)
        }
    }

    private static func scanFileForParameter(
        _ content: String,
        file: String,
        paramRegex: NSRegularExpression
    ) -> [SourceLocation] {
        var locations: [SourceLocation] = []
        let lines = content.components(separatedBy: .newlines)
        var parenDepth = 0
        var inSignature = false

        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if startsSignature(trimmed) {
                inSignature = true
                parenDepth = 0
            }

            guard inSignature else { continue }

            parenDepth += countParens(in: trimmed)

            if matchesParameter(paramRegex, in: line) {
                locations.append(SourceLocation(filePath: file, lineNumber: lineIndex + 1))
            }

            if parenDepth <= 0 { inSignature = false }
        }

        return locations
    }

    private static func startsSignature(_ line: String) -> Bool {
        line.contains("func ") || line.contains("init(")
            || line.contains("init (") || line.contains("subscript(")
            || line.contains("subscript (")
    }

    private static func countParens(in line: String) -> Int {
        var depth = 0
        for char in line {
            if char == Character("(") { depth += 1 }
            if char == Character(")") { depth -= 1 }
        }
        return depth
    }

    private static func findParameterInDocComments(
        _ paramName: String,
        files: [String]
    ) -> [SourceLocation] {
        var locations: [SourceLocation] = []

        for file in files {
            let content: String
            do {
                content = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                logger.warning("Skipping unreadable file \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let lines = content.components(separatedBy: .newlines)

            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                    let lower = trimmed.lowercased()
                    if lower.contains("parameter \(paramName.lowercased()):") ||
                       lower.contains("parameter \(paramName.lowercased()) :") {
                        locations.append(SourceLocation(filePath: file, lineNumber: lineIndex + 1))
                    }
                }
            }
        }

        return locations
    }

    private static func matchesParameter(_ regex: NSRegularExpression, in line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
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
