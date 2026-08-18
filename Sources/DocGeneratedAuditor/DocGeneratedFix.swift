import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// `--fix`: rewrite each stale region from its generator, and change nothing else.
///
/// ## Why this rule may autofix when its neighbours may not
///
/// `doc-code` defers `--fix` because a rename is prose, and rewriting a comment to match a
/// symbol is a guess about what the author meant. `doc-claims` prohibits it outright, because
/// rewriting a documented number to match the program launders a regression into a
/// documentation update — the number was the only thing that would have objected.
///
/// `doc-generated`'s replacement is none of those. It is deterministic, its boundary is
/// explicit, and its correctness is checkable by re-running the check — which is exactly what
/// the tests do rather than asserting the output shape twice.
extension DocGeneratedAuditor: FixableChecker {

    /// What `--fix` will do, shown before it does it.
    public var fixDescription: String {
        "Rewrites the body of each stale `<!-- generated:<id> -->` region from its generator. "
            + "Only the bytes between the delimiters change; tick-boxes and descriptions are "
            + "preserved, and a region no generator can produce is left alone."
    }

    /// Applies fixes against the configuration's resolved project root.
    ///
    /// - Parameters:
    ///   - diagnostics: Ignored, deliberately — see ``fix(projectRoot:configuration:)``.
    ///   - configuration: Supplies the governed set and the generators' inputs.
    /// - Returns: What was rewritten, and which findings were left.
    public func fix(
        diagnostics: [Diagnostic], configuration: Configuration
    ) async throws -> FixResult {
        try await fix(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration)
    }

    /// Applies fixes against an explicit project root.
    ///
    /// The prior diagnostics are not consulted. They describe a state of the tree that may no
    /// longer hold, and every one of them was derived by regenerating the region — so the
    /// honest input is the tree itself, read again now. A fix that trusted a stale finding
    /// could write a body the current source does not produce, which is the one failure mode a
    /// generated document cannot survive.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - configuration: Supplies the governed set and the generators' inputs.
    /// - Returns: One modification per rewritten file, plus the findings left unfixed.
    public func fix(projectRoot: URL, configuration: Configuration) async throws -> FixResult {
        let documents = GovernedDocuments.discover(
            projectRoot: projectRoot, configuration: configuration)

        var modifications: [FileModification] = []
        var unfixed: [Diagnostic] = []

        for document in documents where !document.isExcluded {
            guard let original = try? String(contentsOf: document.url, encoding: .utf8) else { // silent: an unreadable governed document is reported by `check`, and refusing to write one is the correct behaviour here
                continue
            }

            var contents = original
            var rewritten = 0

            for region in RegionScanner.scan(original).regions {
                guard let generator = RegionGeneratorRegistry.generator(for: region.id) else {
                    continue
                }
                let generated: String
                do {
                    generated = try generator.generate(
                        projectRoot: projectRoot,
                        currentBody: region.body,
                        configuration: configuration)
                } catch {
                    // A region nothing can regenerate keeps its bytes. Writing *something*
                    // here would be inventing content, and the finding is the honest outcome.
                    // The reason is logged as well as reported: the diagnostic says the region
                    // was left alone, and the log says which failure left it that way.
                    Self.fixLogger.notice("Region '\(region.id, privacy: .public)' in \(document.relativePath, privacy: .public) was left unchanged: \(error.localizedDescription, privacy: .public)")
                    unfixed.append(Diagnostic(
                        severity: .error,
                        message: "Region `\(region.id)` could not be regenerated, so it was "
                            + "left unchanged.",
                        filePath: document.url.path,
                        lineNumber: region.openingLine,
                        ruleId: "doc-generated.region-ungeneratable"))
                    continue
                }
                guard generated != region.body else { continue }
                guard let updated = RegionFixer.replacingBody(
                    in: contents, id: region.id, with: generated)
                else {
                    continue
                }
                contents = updated
                rewritten += 1
            }

            guard rewritten > 0, contents != original else { continue }
            do {
                try contents.write(to: document.url, atomically: true, encoding: .utf8)
            } catch {
                Self.fixLogger.error("Could not rewrite \(document.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                unfixed.append(Diagnostic(
                    severity: .error,
                    message: "Could not write \(document.relativePath): \(error.localizedDescription)",
                    filePath: document.url.path,
                    ruleId: "doc-generated.fix-write-failed"))
                continue
            }

            let region = rewritten == 1 ? "region" : "regions"
            modifications.append(FileModification(
                filePath: document.relativePath,
                description: "Regenerated \(rewritten) \(region)",
                linesChanged: abs(contents.lines.count - original.lines.count),
                backupPath: nil))
        }

        return FixResult(modifications: modifications, unfixed: unfixed)
    }

    private static let fixLogger = Logger(
        subsystem: "com.quality-gate", category: "DocGeneratedAuditor.fix")
}
