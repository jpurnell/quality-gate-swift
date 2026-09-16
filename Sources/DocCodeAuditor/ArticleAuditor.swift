import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// What the auditor found in one article.
public struct ArticleVerdict: Sendable, Codable {

    /// A name declared more than once at file scope across the article's blocks.
    public struct Collision: Sendable, Codable {
        /// The colliding identifier.
        public let name: String
        /// What it was declared as, at its first site.
        public let kind: String
        /// Every article line that declares it.
        public let articleLines: [Int]
    }

    /// One compile error, located in the article.
    public struct CompileError: Sendable, Codable {
        /// The 1-indexed line in the article, never in the temporary file.
        public let articleLine: Int
        /// The compiler's message, with its `error: ` prefix removed.
        public let message: String
    }

    /// Path of the article audited.
    public let articlePath: String

    /// Swift fences the article contains.
    public let fencesFound: Int

    /// Swift fences compiled.
    public let fencesChecked: Int

    /// Swift fences the author marked `<!-- docs:illustrative -->`.
    public let fencesExempt: Int

    /// Article lines at which exempt fences open.
    public let exemptFenceLines: [Int]

    /// Names declared more than once at file scope.
    public let collisions: [Collision]

    /// Compile errors, at most one per assembled line.
    public let compileErrors: [CompileError]

    /// A module the article imports and the compiler cannot find.
    ///
    /// A `no such module` aborts compilation before typechecking runs, so every error
    /// behind it is invisible. One article ranked as a 1-error job from a detection pass;
    /// its real state was about 27. Reporting the barrier separately is the difference
    /// between an error count that means something and one that does not.
    public let barrier: String?

    /// Whether the article compiles as one program, with no collisions and no barrier.
    public var passed: Bool {
        collisions.isEmpty && compileErrors.isEmpty && barrier == nil
    }

    /// What this article's audit actually examined.
    ///
    /// **A barrier means nothing was examined.** `fencesChecked` counts the fences
    /// handed to the compiler, and it is computed when the article is assembled —
    /// before typechecking runs. A `no such module` aborts the compile, so when a
    /// barrier is reported none of those fences were checked at all.
    ///
    /// Until this property existed the coverage line said `12 Swift fences: 12
    /// checked` for such an article: the exact words a fully examined article
    /// prints. The barrier was reported separately as an error, so the run was not
    /// silent — but its *coverage* was wrong, and a reader totalling checked fences
    /// across a catalogue was counting fences no compiler had seen.
    public var coverage: AnalysisCoverage {
        guard let barrier else {
            return AnalysisCoverage(
                unit: "Swift fence", found: fencesFound,
                examined: fencesChecked, exempt: fencesExempt)
        }
        return AnalysisCoverage(
            unit: "Swift fence", found: fencesFound, examined: 0, exempt: fencesExempt,
            unanalyzed: ["compilation stopped at \(barrier)": fencesChecked])
    }
}

/// Everything the typechecker needs beyond the article itself.
public struct DocCodeAuditOptions: Sendable {

    /// Directory holding the built `.swiftmodule` to compile against, or `nil` for none.
    public var moduleSearchPath: String?

    /// Modules imported in the assembled program's preamble.
    public var imports: [String]

    /// Language-mode flags read from the manifest — `-swift-version`, upcoming features.
    public var languageFlags: [String]

    /// Toolchain flags: the SDK, the platform framework path, the macro plugin path.
    ///
    /// Defaults to a probe of the active toolchain. Without the framework and plugin paths
    /// every `@Test` block fails — first `no such module 'Testing'`, then a missing
    /// `TestingMacros` plugin — and the natural response is to mark those blocks
    /// illustrative, which is a false clean: the gate would have manufactured its own
    /// exemption for a construct it simply could not compile.
    public var toolchainFlags: [String]

    /// Additional header search paths, passed through to Clang.
    public var headerSearchPaths: [String]

    /// Modulemaps named outright, for C targets whose modulemap SwiftPM generated.
    ///
    /// Distinct from ``headerSearchPaths`` because a generated modulemap names its umbrella
    /// header by absolute path and lives nowhere near it: no header search path can find it,
    /// and `-fmodule-map-file=` has to name the file.
    public var moduleMapFiles: [String]

    /// Creates options, probing the toolchain for its defaults.
    public init(
        moduleSearchPath: String? = nil,
        imports: [String] = ["Foundation"],
        languageFlags: [String] = [],
        toolchainFlags: [String] = Toolchain.flags(),
        headerSearchPaths: [String] = [],
        moduleMapFiles: [String] = []
    ) {
        self.moduleSearchPath = moduleSearchPath
        self.imports = imports
        self.languageFlags = languageFlags
        self.toolchainFlags = toolchainFlags
        self.headerSearchPaths = headerSearchPaths
        self.moduleMapFiles = moduleMapFiles
    }
}

/// Assembles, typechecks and inspects one article.
///
/// Stateless and parallel-safe by construction: every audit works in its own temporary
/// directory and shares no mutable state, so any number of articles can be audited at once.
/// Nothing here writes to the package's build tree — it is read from, never into.
public enum ArticleAuditor {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocCodeAuditor")

    /// Audits one article.
    ///
    /// - Parameters:
    ///   - article: The `.md` file.
    ///   - options: Module search path, imports and compiler flags.
    /// - Returns: The verdict, including coverage counts even when the article passes.
    /// - Throws: If the article cannot be read, or the temporary work directory cannot be
    ///   created.
    public static func audit(article: URL, options: DocCodeAuditOptions) throws -> ArticleVerdict {
        let text = try String(contentsOf: article, encoding: .utf8)
        let assembled = ArticleAssembler.assemble(text, imports: options.imports)

        // A directory of our own, so concurrent audits cannot collide — and so the package's
        // `.build` is never written to by this checker.
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let source = work.appendingPathComponent("main.swift")
        try assembled.source.write(to: source, atomically: true, encoding: .utf8)

        let diagnostics = typecheck(source, options: options)

        return ArticleVerdict(
            articlePath: article.path,
            fencesFound: assembled.fencesFound,
            fencesChecked: assembled.fencesChecked,
            fencesExempt: assembled.fencesExempt,
            exemptFenceLines: assembled.exemptFenceLines,
            collisions: collisions(in: assembled, path: source.path),
            compileErrors: diagnostics.errors.map {
                ArticleVerdict.CompileError(
                    articleLine: assembled.articleLine(forAssembledLine: $0.line),
                    message: $0.message)
            },
            barrier: diagnostics.barrier)
    }

    // MARK: - Typecheck

    /// One raw diagnostic from the compiler.
    struct RawError {
        let line: Int
        let message: String
    }

    /// Runs `swiftc -typecheck` and reduces its output to first-per-line errors.
    static func typecheck(
        _ source: URL, options: DocCodeAuditOptions
    ) -> (errors: [RawError], barrier: String?) {
        var arguments = ["swiftc", "-typecheck", source.path, "-diagnostic-style=llvm"]
        if let moduleSearchPath = options.moduleSearchPath {
            arguments += ["-I", moduleSearchPath]
        }
        for path in options.headerSearchPaths {
            arguments += ["-Xcc", "-I\(path)"]
        }
        for path in options.moduleMapFiles {
            arguments += ["-Xcc", "-fmodule-map-file=\(path)"]
        }
        arguments += options.toolchainFlags
        arguments += options.languageFlags

        let output: String
        do {
            // SAFETY: subprocess with `/usr/bin/xcrun swiftc -typecheck` over a file this
            // checker just wrote into its own temporary directory
            let result = try ProcessRunner.run(
                "/usr/bin/xcrun", arguments: arguments, mergeStderr: true, timeout: 300)
            output = result.stdout
        } catch {
            logger.error("Could not run swiftc to typecheck \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ([RawError(line: 1, message: "could not run swiftc: \(error.localizedDescription)")], nil)
        }

        return reduce(output: output)
    }

    /// Reduces raw compiler output to first-per-line errors plus, if any, the barrier that
    /// stopped the compilation.
    ///
    /// Separated from ``typecheck(_:options:)`` so the reduction can be tested without a
    /// toolchain — which is how it was established that the reduction, not the compiler, was
    /// the reason a catalogue reported PASSED having typechecked nothing.
    static func reduce(output: String) -> (errors: [RawError], barrier: String?) {
        var seenLines = Set<Int>()
        var errors: [RawError] = []
        var barrier: String?

        for line in output.lines {
            guard let range = line.range(of: ": error: ") else { continue }
            let message = String(line[range.upperBound...])

            if message.hasPrefix("no such module") || isModuleLoadFailure(message) {
                // This one *does* carry a source location — it names the `import` line — so
                // without the explicit check it would be filed as an ordinary compile error,
                // sending the reader to fix a line whose real problem is the build. Record
                // the first barrier and keep going; the rest of the output behind it is not
                // a measurement of the documentation.
                barrier = barrier ?? message
            }

            guard let number = lineNumber(inHead: line[line.startIndex..<range.lowerBound]) else {
                // An error the compiler could not attach to a line of the assembled program
                // is, by construction, not a statement about a line of the article — it is a
                // statement about whether the article could be read at all. Discarding it
                // was how `missing required module '_SwiftSyntaxCShims'` became invisible,
                // leaving `(errors: [], barrier: nil)`: a verdict indistinguishable from a
                // clean article, for a compilation that never reached typechecking.
                //
                // Structural rather than a list of phrasings, deliberately. A list would
                // have to be extended every time the compiler learns a new way to say it
                // could not proceed, and the cost of missing an entry is silence.
                barrier = barrier ?? message
                continue
            }
            // One error per source line. The rest are cascade: a single unresolved
            // identifier produces a dozen downstream complaints, and reporting all of them
            // makes the article look far worse than the repair actually is.
            guard seenLines.insert(number).inserted else { continue }
            errors.append(RawError(line: number, message: message))
        }

        // Everything *behind* a barrier is cascade, not measurement. Keeping it is how one
        // unloadable module became 605 findings across 57 projects on 2026-09-02, each one
        // phrased as a claim about the author's documentation: an unresolvable `some
        // Protocol` in a signature puts every parameter out of scope, and `cannot find 'x'
        // in scope` is reported as "nothing in the fence defines 'x'" against code that is
        // correct.
        //
        // The barrier's *own* located error is kept, which is why this filters by message
        // rather than clearing the list. A located barrier is reported twice on purpose —
        // once as the barrier, once against the import line the reader has to edit — and
        // clearing outright deleted that second report, breaking the `no such module`
        // contract while fixing the cascade. The reader still gets one actionable line,
        // and it says `rebuild` instead of naming innocent ones.
        guard let barrier else { return (errors, nil) }
        return (errors.filter { $0.message == barrier }, barrier)
    }

    /// Whether a *located* error is really about the build rather than the line it names.
    ///
    /// The compiler attaches these to the `import` line, so without an explicit check they
    /// are filed as ordinary compile errors — the same trap ``reduce(output:)`` already
    /// avoids for `no such module`. Both directions are matched on purpose: a toolchain
    /// moves forward when a beta is adopted and backward when it is abandoned, and a
    /// machine carrying both Xcode and Xcode-beta can produce either message on any day.
    ///
    /// Matched by phrase rather than structurally because these carry a location, which is
    /// exactly what the structural test uses to decide. The cost of a missing phrase is a
    /// wrong verdict, so a new one belongs here the day it is first seen.
    ///
    /// The phrase stops before the direction on purpose. Matching "an older version" missed
    /// "a different version of the compiler '6.4.0.33.1'" — what a build-number change
    /// says — on 2026-09-15, and 65 of 74 corpus projects read as broken documentation.
    static func isModuleLoadFailure(_ message: String) -> Bool {
        message.contains("compiled module was created by")
            || message.contains("cannot be imported by the Swift")
    }

    /// The line number in a `path:LINE:COL` diagnostic head.
    ///
    /// Scanned from the right, so a path containing a colon cannot shift the fields.
    static func lineNumber(inHead head: Substring) -> Int? {
        let parts = head.components(separatedBy: ":")
        guard parts.count >= 3 else { return nil }
        return Int(parts[parts.count - 2])
    }

    // MARK: - Collisions

    /// Names declared more than once at file scope, ranked by how many sites they touch.
    ///
    /// Worth detecting separately from the compile errors, because a collision does not
    /// always produce one: top-level code accepts the second declaration and only complains
    /// at a *use* — so a colliding pair that is never read again compiles cleanly today and
    /// breaks the moment someone adds a line.
    static func collisions(in assembled: AssembledArticle, path: String) -> [ArticleVerdict.Collision] {
        let tree = Parser.parse(source: assembled.source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let collector = DeclarationCollector(converter: converter) {
            assembled.articleLine(forAssembledLine: $0)
        }
        collector.walk(tree)

        return Dictionary(grouping: collector.declarations, by: \.name)
            .filter { $0.value.count > 1 }
            .map { name, sites in
                ArticleVerdict.Collision(
                    name: name,
                    kind: sites[0].kind,
                    articleLines: sites.map(\.articleLine).sorted())
            }
            .sorted {
                $0.articleLines.count != $1.articleLines.count
                    ? $0.articleLines.count > $1.articleLines.count
                    : $0.name < $1.name
            }
    }
}
