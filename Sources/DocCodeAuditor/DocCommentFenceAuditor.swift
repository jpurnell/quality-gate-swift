import Foundation

/// What the compiler said about one doc-comment fence.
public struct DocCommentFenceVerdict: Sendable, Codable {

    /// One compile error, located in the `.swift` file the doc comment lives in.
    public struct CompileError: Sendable, Codable, Equatable {
        /// The 1-indexed line in the `.swift` file, never in the temporary program.
        public let fileLine: Int
        /// The compiler's message, with its `error: ` prefix removed.
        public let message: String
    }

    /// Path of the file the fence was extracted from.
    public let filePath: String

    /// 1-indexed line of the fence's opening delimiter.
    public let fenceOpenLine: Int

    /// Name of the declaration the doc comment is attached to, if it has one.
    public let declarationName: String?

    /// Compile errors, at most one per line of the fence.
    public let compileErrors: [CompileError]

    /// A module the fence imports and the compiler cannot find.
    ///
    /// Reported apart from the compile errors because a `no such module` aborts compilation
    /// before typechecking runs: every error behind it is invisible, so an error count that
    /// includes it means nothing. It is also the shape the `QualityGateTestKit` fences take —
    /// a doc comment demonstrating itself against a module its own target is forbidden to
    /// depend on — where the reader's problem is the build graph, not the line the compiler
    /// pointed at.
    public let barrier: String?

    /// Whether the fence compiles.
    public var passed: Bool { compileErrors.isEmpty && barrier == nil }
}

/// Compiles one doc-comment fence, on its own, as one program.
///
/// Stateless and parallel-safe by construction: every audit works in its own temporary
/// directory and shares no mutable state. Nothing here writes to the package's build tree —
/// it is read from, never into.
///
/// ## Why one fence and not one doc comment
///
/// `HIGAuditor.swift` carries a single `///` run holding two swift fences separated by an
/// `## Exemptions` heading. The first is a usage example; the second is a fragment of *the
/// reader's* SwiftUI code. Concatenating them would buy no shared bindings and would import
/// `doc-code`'s collision rule into a place where its premise — *an article is one program,
/// pasted into a playground end to end* — is false. Nobody pastes a Quick Help panel. A name
/// declared in two fences of the same doc comment is not a defect, and no collision detection
/// runs here.
public enum DocCommentFenceAuditor {

    /// Compiles one fence and locates the diagnostics back in the `.swift` file.
    ///
    /// - Parameters:
    ///   - fence: The fence to compile. Callers are expected to have filtered on
    ///     ``DocCommentFence/isCheckable``; a non-Swift or exempt fence compiled here would
    ///     be a coverage lie in the other direction.
    ///   - options: Module search path, preamble imports and compiler flags.
    /// - Returns: The verdict, with every line number already in `.swift` coordinates.
    /// - Throws: If the temporary work directory cannot be created or written to.
    public static func audit(
        _ fence: DocCommentFence, options: DocCodeAuditOptions
    ) throws -> DocCommentFenceVerdict {
        // A directory of our own, so concurrent audits cannot collide — and so the package's
        // `.build` is never written to by this checker.
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-comment-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Always `main.swift`. Most doc-comment fences are bare statements rather than
        // declarations, and only a file with that name accepts top-level code — including
        // `try await`, under the top-level concurrency rules. Declaration-only fences are
        // equally happy under it.
        let source = work.appendingPathComponent("main.swift")
        try program(for: fence, imports: options.imports)
            .write(to: source, atomically: true, encoding: .utf8)

        let diagnostics = ArticleAuditor.typecheck(source, options: options)
        let preamble = preambleLineCount(imports: options.imports)

        return DocCommentFenceVerdict(
            filePath: fence.filePath,
            fenceOpenLine: fence.openLine,
            declarationName: fence.declarationName,
            compileErrors: diagnostics.errors.map {
                DocCommentFenceVerdict.CompileError(
                    fileLine: fileLine(
                        compiledLine: $0.line,
                        fenceOpenLine: fence.openLine,
                        preambleLines: preamble),
                    message: $0.message)
            },
            barrier: diagnostics.barrier)
    }

    /// The program compiled for one fence: the preamble, a blank line, then the fence body.
    ///
    /// The preamble is `Foundation` plus the module the doc comment lives in, and nothing
    /// else. The generous alternatives were measured and both rejected: injecting the
    /// module's dependency closure would have turned ten of this repository's sixteen
    /// failures into passes while the examples stayed uncopyable — the missing `import` *is*
    /// the defect — and it could not have fixed the four fences that reference a module their
    /// target is forbidden to depend on at any depth. A preamble generous enough to make the
    /// corpus green is a preamble that certifies documentation the reader cannot use.
    ///
    /// - Parameters:
    ///   - fence: The fence whose body becomes the program.
    ///   - imports: The preamble modules, in order.
    /// - Returns: The full program text, newline-terminated.
    public static func program(for fence: DocCommentFence, imports: [String]) -> String {
        (imports.map { "import \($0)" } + [""] + fence.body).joined(separator: "\n") + "\n"
    }

    /// Lines the preamble occupies: one per import, plus the blank separator.
    static func preambleLineCount(imports: [String]) -> Int { imports.count + 1 }

    /// The `.swift` line a compiled line came from.
    ///
    /// With one fence per program the arithmetic is direct and needs no line map: the fence
    /// body starts on the line after the opener, and the preamble is a fixed prefix. Verified
    /// end to end against `BuildChecker.swift`, whose fence opens at line 14 — the compiler
    /// reports line 5 of a 3-line preamble, and 14 + (5 − 3) = 16, which is the line that
    /// actually names `config`.
    ///
    /// Clamped at the fence opener, because a diagnostic the compiler attached to the
    /// preamble is a statement about the fence as a whole rather than about a line the author
    /// wrote, and pointing at a line before the doc comment would be worse than useless.
    ///
    /// Line only, never column: stripping `///` shifts every column left by a prefix width
    /// that is not constant across files, since a doc comment on a nested declaration is
    /// indented. Reporting a column would be reporting a number that is quietly wrong.
    ///
    /// - Parameters:
    ///   - compiledLine: 1-indexed line in the temporary program.
    ///   - fenceOpenLine: 1-indexed `.swift` line of the fence's opening delimiter.
    ///   - preambleLines: Lines the preamble occupies.
    /// - Returns: The 1-indexed `.swift` line.
    public static func fileLine(compiledLine: Int, fenceOpenLine: Int, preambleLines: Int) -> Int {
        max(fenceOpenLine, fenceOpenLine + (compiledLine - preambleLines))
    }
}
