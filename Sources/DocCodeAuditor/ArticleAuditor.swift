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

    /// Creates options, probing the toolchain for its defaults.
    public init(
        moduleSearchPath: String? = nil,
        imports: [String] = ["Foundation"],
        languageFlags: [String] = [],
        toolchainFlags: [String] = Toolchain.flags(),
        headerSearchPaths: [String] = []
    ) {
        self.moduleSearchPath = moduleSearchPath
        self.imports = imports
        self.languageFlags = languageFlags
        self.toolchainFlags = toolchainFlags
        self.headerSearchPaths = headerSearchPaths
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
        arguments += options.toolchainFlags
        arguments += options.languageFlags

        let process = Process()
        let pipe = Pipe()
        // SAFETY: subprocess with `/usr/bin/xcrun swiftc -typecheck` over a file this
        // checker just wrote into its own temporary directory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        let output: String
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            output = String(data: data, encoding: .utf8) ?? ""
        } catch {
            logger.error("Could not run swiftc to typecheck \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ([RawError(line: 1, message: "could not run swiftc: \(error.localizedDescription)")], nil)
        }

        var seenLines = Set<Int>()
        var errors: [RawError] = []
        var barrier: String?

        for line in output.lines {
            guard let range = line.range(of: ": error: ") else { continue }
            let message = String(line[range.upperBound...])

            if message.hasPrefix("no such module") {
                // Record the first barrier and keep going; the rest of the output behind it
                // is not a measurement of the documentation.
                barrier = barrier ?? message
            }

            guard let number = lineNumber(inHead: line[line.startIndex..<range.lowerBound]) else {
                continue
            }
            // One error per source line. The rest are cascade: a single unresolved
            // identifier produces a dozen downstream complaints, and reporting all of them
            // makes the article look far worse than the repair actually is.
            guard seenLines.insert(number).inserted else { continue }
            errors.append(RawError(line: number, message: message))
        }

        return (errors, barrier)
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
