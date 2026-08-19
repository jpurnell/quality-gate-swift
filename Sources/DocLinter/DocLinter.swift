import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
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
/// import QualityGateCore
///
/// let config = Configuration()
/// let linter = DocLinter()
/// let result = try await linter.check(configuration: config)
/// ```
public struct DocLinter: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocLinter")

    /// Unique identifier for this checker.
    public let id = "doc-lint"

    /// Human-readable name for this checker.
    public let name = "Documentation Linter"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "DocC documentation build errors"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.documentation

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.documentation

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Creates a new DocLinter instance.
    public init() {}

    /// Declares this checker cacheable on the source tree **and the DocC catalogues**.
    ///
    /// `wholeSource` would be an under-specification here. It collects `.swift` files, and this
    /// checker also reads the `.md` inside `.docc` catalogues — so an edited article would keep a
    /// stale verdict. `wholeSourceAndDocs` covers what is actually read.
    ///
    /// The DocC build this spawns is a function of the same sources plus the toolchain, and
    /// `gateIdentityHash` folds the toolchain version and the gate binary's own identity into
    /// every key. A verdict is never replayed across a toolchain that did not produce it.
    ///
    /// At ~208s this is the largest remaining item in the gate once `test` is cached.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Run the documentation linter.
    ///
    /// Executes `swift package generate-documentation` and parses any diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let projectRoot = configuration.resolvedProjectRoot.path
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

        // Every target that owns a catalogue, not the first one that happens to appear in the
        // manifest. `--target` is repeatable, so full coverage costs one invocation.
        //
        // The old behaviour took the first target of the first `.library` product and asked DocC
        // about that alone — so a green `doc-lint` was a statement about one module out of 116,
        // and the other 115 were never handed to DocC at all. That is not degraded coverage, it
        // is absent coverage reported as a pass.
        let documented = Self.documentedTargets(projectRoot: projectRoot)
        let explicit = configuration.docTarget

        if let target = explicit {
            // An explicitly configured target is still honoured: a project that says "document
            // this one" is answering a different question and should get what it asked for.
            arguments.append("--target")
            arguments.append(target)
        } else if !documented.isEmpty {
            for target in documented {
                arguments.append("--target")
                arguments.append(target)
            }
        } else if let target = Self.resolveDocTarget(
            configured: nil,
            packageContent: packageContent
        ) {
            arguments.append("--target")
            arguments.append(target)
        } else if !packageContent.isEmpty && Self.isExecutableOnly(packageContent) {
            let duration = ContinuousClock.now - startTime
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "Executable-only package — no library target for DocC symbol graph generation.",
                        ruleId: "doc-lint-skip"
                    )
                ],
                duration: duration
            )
        }

        // Run swift package generate-documentation
        // SAFETY: runs swift package generate-documentation to lint DocC coverage
        let result: ProcessRunner.Output
        do {
            result = try ProcessRunner.run(
                "/usr/bin/swift",
                arguments: arguments,
                currentDirectory: projectRoot
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
        var diagnostics = enrichedDiagnostics
        diagnostics += Self.ambiguousLinkDiagnostics(projectRoot: projectRoot)
        let coverage = Self.coverageDiagnostic(explicit: explicit, documented: documented)
        diagnostics.append(coverage)

        return CheckResult(
            checkerId: id,
            status: coverage.severity == .error ? .failed : baseResult.status,
            diagnostics: diagnostics,
            duration: duration
        )
    }


    /// Symbol links that could mean this package's type or the standard library's.
    ///
    /// Scoped by construction: the declared-type scan looks only for names in
    /// ``AmbiguousSymbolLink/stdlibNames``, so a package that declares no colliding
    /// type does no reference scanning at all and this costs one directory walk.
    ///
    /// Runs alongside DocC's own findings rather than inside them, because DocC
    /// resolves a bare link happily — the ambiguity is invisible to it by design.
    /// That is precisely why the rule exists.
    ///
    /// - Parameter projectRoot: The package root.
    /// - Returns: One warning per ambiguous reference, ordered by file then line.
    static func ambiguousLinkDiagnostics(projectRoot: String) -> [Diagnostic] {
        let declared = DeclaredTypes.colliding(
            projectRoot: projectRoot, names: AmbiguousSymbolLink.stdlibNames)
        guard !declared.isEmpty else { return [] }

        var diagnostics: [Diagnostic] = []
        for spelling in ["Sources", "Source", "src"] {
            let root = URL(fileURLWithPath: projectRoot).appendingPathComponent(spelling)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker {
                let isArticle = url.pathExtension == "md"
                let isSwift = url.pathExtension == "swift"
                guard isArticle || isSwift else { continue }
                // silent: an unreadable file yields no findings; it is already DocC's to report
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                // In Swift, only doc comments carry symbol links; ordinary comments and
                // string literals containing double backticks are not references.
                let searchable = isSwift
                    ? text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("///") ? String($0) : "" }
                        .joined(separator: "\n")
                    : text
                diagnostics += AmbiguousSymbolLink
                    .findings(in: searchable, declaredLocally: declared)
                    .map { AmbiguousSymbolLink.diagnostic(for: $0, path: url.path) }
            }
        }
        return diagnostics.sorted {
            ($0.filePath ?? "", $0.lineNumber ?? 0) < ($1.filePath ?? "", $1.lineNumber ?? 0)
        }
    }

    /// Every target that owns a DocC catalogue, sorted.
    ///
    /// Probes the three directory names SwiftPM permits, for the same reason the C-modulemap
    /// search does: `Sources` is the convention, not the rule, and a project laid out with
    /// `Source/` would otherwise yield an empty list — which is indistinguishable from a project
    /// with no documentation, and passes.
    ///
    /// - Parameter projectRoot: The package root.
    /// - Returns: Target names owning a `.docc`, sorted for a stable command line.
    static func documentedTargets(projectRoot: String) -> [String] {
        let manager = FileManager.default
        var targets: Set<String> = []

        for spelling in ["Sources", "Source", "src"] {
            let root = (projectRoot as NSString).appendingPathComponent(spelling)
            // silent: most packages have only one of the three spellings, so an absent directory is the ordinary case
            let entries = (try? manager.contentsOfDirectory(atPath: root)) ?? []
            for entry in entries {
                let module = (root as NSString).appendingPathComponent(entry)
                // silent: a file rather than a directory under Sources/ simply owns no catalogue
                let contents = (try? manager.contentsOfDirectory(atPath: module)) ?? []
                if contents.contains(where: { $0.hasSuffix(".docc") }) {
                    targets.insert(entry)
                }
            }
        }
        return targets.sorted()
    }

    /// What the run examined, stated whether it passed or failed.
    ///
    /// A checker that examined nothing and a checker that found nothing wrong must not print the
    /// same thing. `doc-generated` already reports its region count on every run for exactly this
    /// reason; `doc-lint` was written without it, and the consequence was a green verdict over
    /// one module out of 116 that nobody could see from the output.
    ///
    /// - Parameters:
    ///   - explicit: The configured `docTarget`, when one narrowed the run.
    ///   - documented: The targets found to own a catalogue.
    /// - Returns: A note describing coverage, or an error when nothing was examined.
    static func coverageDiagnostic(explicit: String?, documented: [String]) -> Diagnostic {
        if let explicit {
            return Diagnostic(
                severity: .note,
                message: "doc-lint examined 1 target (`\(explicit)`), because `docTarget` is "
                    + "configured. \(documented.count) target(s) own a catalogue; the rest were "
                    + "not handed to DocC.",
                ruleId: "doc-lint.coverage")
        }
        guard !documented.isEmpty else {
            return Diagnostic(
                severity: .error,
                message: "doc-lint found no target owning a `.docc` catalogue, so it examined "
                    + "nothing. A pass here would mean only that there was nothing to look at.",
                ruleId: "doc-lint.no-coverage",
                suggestedFix: "Add a catalogue, set `docTarget` explicitly, or exclude `doc-lint` "
                    + "if this package is not documented with DocC.")
        }
        return Diagnostic(
            severity: .note,
            message: "doc-lint examined \(documented.count) target(s) owning a DocC catalogue.",
            ruleId: "doc-lint.coverage")
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


    /// The location DocC printed beneath a diagnostic, if it printed one.
    ///
    /// Blank lines between the message and its `-->` are tolerated. Anything else ends the
    /// search, so a diagnostic with no location of its own can never adopt the next one's — the
    /// whole point of this change is that a wrong address is worse than none.
    ///
    /// - Parameters:
    ///   - index: The line the message was found on.
    ///   - lines: Every line of the output.
    ///   - regex: The compiled continuation pattern.
    /// - Returns: The path, line and column, or `nil` when no continuation follows.
    static func locationBelow(
        index: Int, lines: [String], regex: NSRegularExpression
    ) -> (path: String, line: Int, column: Int)? {
        var cursor = index + 1
        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
            if candidate.isEmpty { cursor += 1; continue }
            let range = NSRange(candidate.startIndex..., in: candidate)
            guard let match = regex.firstMatch(in: candidate, options: [], range: range) else {
                return nil
            }
            let path = extractGroup(match, group: 1, from: candidate)
            let line = Int(extractGroup(match, group: 2, from: candidate)) ?? 0
            let column = Int(extractGroup(match, group: 3, from: candidate)) ?? 0
            return (resolve(path: path), line, column)
        }
        return nil
    }

    /// Makes a DocC-relative path readable.
    ///
    /// DocC resolves these against the symbol-graph location, not the package root, so they
    /// arrive as `../Portfolio/PortfolioUtilities.swift`. Printing that verbatim points a reader
    /// at a path that does not exist. When the suffix identifies exactly one file under the
    /// project, that file is the answer; when it identifies several, the relative path is kept
    /// rather than a guess being made between them.
    ///
    /// - Parameter path: The path as DocC wrote it.
    /// - Returns: An absolute path when one is unambiguous, else the input unchanged.
    static func resolve(path: String) -> String {
        guard path.hasPrefix("..") || !path.hasPrefix("/") else { return path }
        let root = FileManager.default.currentDirectoryPath
        let name = (path as NSString).lastPathComponent
        let manager = FileManager.default

        var matches: [String] = []
        for spelling in ["Sources", "Source", "src", "Tests"] {
            let directory = (root as NSString).appendingPathComponent(spelling)
            guard let walker = manager.enumerator(atPath: directory) else { continue }
            for case let relative as String in walker where (relative as NSString).lastPathComponent == name {
                matches.append((directory as NSString).appendingPathComponent(relative))
                if matches.count > 1 { return path }
            }
        }
        return matches.count == 1 ? matches[0] : path
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
        let lines = output.lines

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

        // Modern DocC (Swift 6.4) puts the message and the location on separate lines:
        //
        //     warning: Parameter 'seed' is missing documentation
        //        --> ../Portfolio/PortfolioUtilities.swift:103:54-103:54
        //
        // Neither supported shape matched that, so every location was dropped and then guessed
        // from an unrelated ordering. Measured on the run that found this: 0 of the diagnostics
        // used the inline format — the supported paths were not incomplete, they were unreached.
        // The end of the range is optional because it must be tolerated, not because it is used.
        let continuationPattern = #"^\s*-->\s*(.+?):(\d+):(\d+)(?:-\d+:\d+)?$"#
        let simpleRegex: NSRegularExpression?
        do {
            simpleRegex = try NSRegularExpression(pattern: simplePattern, options: [])
        } catch {
            logger.warning("Failed to compile simple-severity regex: \(error.localizedDescription, privacy: .public)")
            simpleRegex = nil
        }

        let continuationRegex: NSRegularExpression?
        do {
            continuationRegex = try NSRegularExpression(pattern: continuationPattern, options: [])
        } catch {
            logger.warning("Failed to compile continuation regex: \(error.localizedDescription, privacy: .public)")
            continuationRegex = nil
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A continuation belongs to the diagnostic above it and is never one itself.
            if trimmed.hasPrefix("-->") { continue }
            // DocC prints the offending source under the location, with `|` gutters and a
            // `╰─suggestion:` marker. None of it is a finding.
            if trimmed.contains("╰─") { continue }

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

                // The location, if DocC put it on a following line. Blank lines between the two
                // are tolerated; anything else ends the search, so a message with no location of
                // its own never adopts the next diagnostic's.
                if let continuationRegex,
                   let location = Self.locationBelow(
                    index: index, lines: lines, regex: continuationRegex) {
                    diagnostics.append(Diagnostic(
                        severity: DependencyBuildNoise.isNoise(message) ? .note : severity,
                        message: message,
                        filePath: location.path,
                        lineNumber: location.line,
                        columnNumber: location.column,
                        ruleId: DependencyBuildNoise.isNoise(message)
                            ? "doc-lint.dependency-build-noise"
                            : "docc"))
                    continue
                }

                diagnostics.append(Diagnostic(
                    severity: DependencyBuildNoise.isNoise(message) ? .note : severity,
                    message: DependencyBuildNoise.isNoise(message)
                        ? "\(message) — build-graph noise from a dependency artifact; the project under test cannot act on it."
                        : message,
                    ruleId: DependencyBuildNoise.isNoise(message)
                        ? "doc-lint.dependency-build-noise"
                        : "docc"
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

    /// Returns true if the Package.swift defines executable products but no library products.
    ///
    /// Swift 6.3's docc-plugin can't generate symbol graphs for executable targets
    /// (output lands in `ExecutableModules/` instead of `Products/`), so doc-lint
    /// skips these packages gracefully.
    public static func isExecutableOnly(_ packageContent: String) -> Bool {
        let hasLibrary = packageContent.contains(".library(")
        let hasExecutable = packageContent.contains(".executable(") || packageContent.contains(".executableTarget(")
        return hasExecutable && !hasLibrary
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

            for entry in entries {
                let locations = entry.isNotFound ? docLocations : sigLocations

                // Only a unique answer is used. The previous version paired the i-th diagnostic
                // with the i-th signature found, but `entries` follows DocC's emission order and
                // the location list follows file traversal order — two orderings nothing aligns.
                // With one `seed:` parameter in a package the guess landed by luck; with eight,
                // every guess missed and sent three investigations to files that were correct.
                //
                // The `locations.last` fallback was worse still: once diagnostics outnumbered
                // locations, every remaining one was assigned the same arbitrary file. It cannot
                // be right and can only mislead, so it is gone rather than narrowed.
                guard locations.count == 1, let loc = locations.first else { continue }
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
            let lines = content.lines

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
            let lines = content.lines
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
        let lines = content.lines
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
            let lines = content.lines

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

    /// Maps DocC's severity word onto a ``Diagnostic/Severity``.
    ///
    /// Internal rather than private so its totality can be asserted: every input maps
    /// to a severity, and an unrecognised one degrades to `.warning` rather than
    /// causing the diagnostic to be dropped. A dropped diagnostic is a finding the
    /// reader never sees, which is the failure mode this checker has already had once.
    static func parseSeverity(_ string: String) -> Diagnostic.Severity {
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
