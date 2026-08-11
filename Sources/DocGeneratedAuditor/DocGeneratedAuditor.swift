import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// Checks that derived content committed as prose still matches what it was derived from.
///
/// A `<!-- generated:<id> -->` … `<!-- /generated:<id> -->` region hands the bytes between
/// the delimiters to a named generator. The checker regenerates each region in memory and
/// compares; everything outside the delimiters belongs to the author and is never read as a
/// claim about anything.
///
/// ## It converts a temporal question into a hermetic one
///
/// This is the reason the rule can govern documents `status` cannot. "Is this document
/// stale?" depends on the calendar, so `StatusValidator` clamps it to `.note` and it can
/// never block a commit. "Does this table disagree with the tree?" depends on nothing but the
/// tree, so it always can — and it comes due at the commit that causes the drift, which is
/// the only moment repairing it costs one line.
///
/// ## Nothing declared by a document may decide the document's verdict
///
/// Generators are compiled into the binary and enumerable from it. There is no configured
/// command, in any phase: `GatePlugins` may execute a configured executable only because a
/// plugin's verdict is advisory by default, and this rule gates. Independently of that, a
/// reference nominated by the thing under test verifies nothing — whoever can write a stale
/// region can also write the command that reproduces it.
///
/// ## What it cannot catch
///
/// - **Whether the surrounding narrative is true.** A perfectly regenerated table can sit
///   inside a paragraph that contradicts it, and a green gate beside a wrong sentence reads
///   as an endorsement of the sentence.
/// - **Whether a tick-box is true.** By construction: the roster generators own membership
///   and never touch state, so a fully-green roster beside a column of wrong tick-boxes is a
///   reachable state. `status` owns that column.
/// - **Anything nobody wrapped in delimiters.** Regions are opt-in per site.
/// - **Behaviour, as distinct from structure.** A generator can enumerate an enum's cases; it
///   cannot tell you which of them anything actually does.
public struct DocGeneratedAuditor: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocGeneratedAuditor")

    /// Unique identifier for this checker.
    public let id = "doc-generated"

    /// Human-readable name for this checker.
    public let name = "Generated Content Auditor"

    /// Pure read plus an in-memory regeneration: no build lock, no subprocess.
    public var isParallelSafe: Bool { true }

    /// A function of the working tree, which is exactly what buys the authority to gate.
    ///
    /// The guarantee is structural rather than declared: `hermeticity` is answered before any
    /// file is read, so it cannot depend on which generators happen to match regions in this
    /// tree. `RegionGenerator` therefore admits only conformances that read files under the
    /// project root — no clock, no network, no git refs, no environment.
    public var hermeticity: Hermeticity { .hermetic }

    /// Creates a new auditor.
    public init() {}

    /// Inputs whose change could change the verdict.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        Self.cacheInputs(
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configuration: configuration)
    }

    /// Inputs whose change could change the verdict, for a given root.
    ///
    /// Deliberately over-inclusive. Over-including costs a cache miss; under-including is the
    /// only way a cache can serve a verdict that is simply wrong. The governed documents are
    /// listed explicitly because a source-only helper would miss them entirely, and a stale
    /// pass on an edited document is precisely the failure this checker exists to prevent.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - configuration: Supplies the governed set and the config slice folded into the salt.
    /// - Returns: The declared input set.
    public static func cacheInputs(projectRoot: URL, configuration: Configuration) -> CacheInputs? {
        var files = GovernedDocuments.discover(projectRoot: projectRoot, configuration: configuration)
            .map(\.url.path)

        for manifest in ["Package.swift", "Package.resolved"] {
            let url = projectRoot.appendingPathComponent(manifest)
            // SAFETY: CLI tool checks for the project's own manifest
            if FileManager.default.fileExists(atPath: url.path) { files.append(url.path) }
        }

        var salt = ""
        if let encoded = try? JSONEncoder().encode(configuration.docGenerated) { // silent: the config slice is plain Codable values; an unsalted fingerprint only costs a stale-cache risk the file list already covers
            salt = CheckerFingerprint.digest(of: encoded)
        }
        return CacheInputs(files: files.sorted(), salt: salt)
    }

    /// Runs the check against the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        try await check(
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configuration: configuration)
    }

    /// Runs the check against an explicit project root.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - configuration: Supplies the governed-file set and the generators' inputs.
    /// - Returns: The check result, always carrying a coverage note.
    public func check(projectRoot: URL, configuration: Configuration) async throws -> CheckResult {
        let started = ContinuousClock.now
        let documents = GovernedDocuments.discover(
            projectRoot: projectRoot, configuration: configuration)

        var diagnostics: [Diagnostic] = []
        var coverage = RegionCoverage()

        for document in documents {
            let contents: String
            do {
                contents = try String(contentsOf: document.url, encoding: .utf8)
            } catch {
                Self.logger.error("Cannot read governed document \(document.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "Cannot read governed document: \(error.localizedDescription)",
                    filePath: document.relativePath,
                    ruleId: "doc-generated.document-unreadable"))
                continue
            }

            let scan = RegionScanner.scan(contents)

            guard !document.isExcluded else {
                coverage.regionsNotScanned += scan.regions.count
                coverage.filesNotScanned += 1
                continue
            }

            diagnostics += scan.defects.map { defect in
                Diagnostic(
                    severity: .error,
                    message: defect.message,
                    filePath: document.relativePath,
                    lineNumber: defect.line,
                    ruleId: defect.ruleId)
            }

            for region in scan.regions {
                coverage.regionsFound += 1
                coverage.unknownIDs += 1
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "No generator is registered for region `\(region.id)`. "
                        + "A region nothing can regenerate reads as governed and is not.",
                    filePath: document.relativePath,
                    lineNumber: region.openingLine,
                    ruleId: "doc-generated.region-unknown-id",
                    suggestedFix: "Correct the id, remove the delimiters, or contribute a "
                        + "`RegionGenerator` conformance for `\(region.id)`."))
            }

            diagnostics += SelfContradictionRule.contradictions(in: contents).map { contradiction in
                Diagnostic(
                    severity: .error,
                    message: contradiction.message,
                    filePath: document.relativePath,
                    lineNumber: contradiction.line,
                    ruleId: contradiction.ruleId,
                    suggestedFix: "Decide which side is true and make both lines say it.")
            }
        }

        diagnostics.append(Diagnostic(
            severity: .note,
            message: coverage.summary,
            ruleId: "doc-generated.coverage"))

        let failed = diagnostics.contains { $0.severity == .error }
        return CheckResult(
            checkerId: id,
            status: failed ? .failed : .passed,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - started)
    }
}

/// What one run saw, reported whether it passed or failed.
///
/// A gate that under-reports its own coverage is indistinguishable from a gate that passes,
/// so this line is printed in every mode — including the mode where the answer is zero.
struct RegionCoverage {
    var regionsFound = 0
    var regionsRegenerated = 0
    var unknownIDs = 0
    var generatorsUnused = 0
    var regionsNotScanned = 0
    var filesNotScanned = 0

    var summary: String {
        var parts = [
            "regions: \(regionsFound) found",
            "\(regionsRegenerated) regenerated",
            "\(unknownIDs) unknown",
            "\(generatorsUnused) generators unused",
        ]
        if filesNotScanned > 0 {
            let files = filesNotScanned == 1 ? "file" : "files"
            parts.append("\(regionsNotScanned) in \(filesNotScanned) excluded \(files) not scanned")
        }
        return parts.joined(separator: " · ")
    }
}
