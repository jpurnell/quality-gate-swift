import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import QualityGateCore

/// Audits SPM dependency checkouts for git submodules.
///
/// Private submodules in published packages cause SPM resolution failures
/// in CI environments that lack tokens for the submodule repo. This checker
/// scans `.build/checkouts/` for any `.gitmodules` file and flags it.
///
/// ## Rules
///
/// | Rule ID | What it flags | Severity |
/// |---|---|---|
/// | `dep-submodule` | SPM dependency contains a `.gitmodules` file | error |
///
/// ## Usage
///
/// ```swift
/// import QualityGateCore
///
/// let config = Configuration()
/// let auditor = SubmoduleAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
public struct SubmoduleAuditor: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "SubmoduleAuditor")

    /// Unique identifier for this checker.
    public let id = "submodule-audit"

    /// Human-readable name for display.
    public let name = "Submodule Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Git submodule pin and allowlist compliance"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.projectHealth

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Creates a new SubmoduleAuditor instance.
    public init() {}

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or out-of-tree path
    /// among its inputs — so the same tree under the same gate binary yields the same verdict.
    /// `gateIdentityHash` folds in the binary's identity and the toolchain, so a rebuild or a
    /// compiler change invalidates every entry.
    ///
    /// `wholeSourceAndDocs` rather than `wholeSource`: it is the wider set, and over-including
    /// an input costs a cache miss while under-including one serves a stale pass.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Run the submodule audit against `.build/checkouts`.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let clock = ContinuousClock()
        let start = clock.now

        let projectRoot = configuration.resolvedProjectRoot.path
        let checkoutsPath = projectRoot + "/.build/checkouts"
        var diagnostics: [Diagnostic] = []

        guard FileManager.default.fileExists(atPath: checkoutsPath) else {
            let elapsed = clock.now - start
            Self.logger.info("No .build/checkouts directory — skipping submodule audit")
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [],
                duration: elapsed
            )
        }

        let checkouts: [String]
        do {
            checkouts = try FileManager.default.contentsOfDirectory(atPath: checkoutsPath)
        } catch {
            Self.logger.warning("Cannot list .build/checkouts: \(error.localizedDescription, privacy: .public)")
            let elapsed = clock.now - start
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [],
                duration: elapsed
            )
        }

        let allowedPackages = Set(configuration.submoduleAudit.allowedPackages)

        for packageDir in checkouts {
            if allowedPackages.contains(packageDir) {
                Self.logger.info("Skipping allowed package '\(packageDir, privacy: .public)'")
                continue
            }

            let gitmodulesPath = checkoutsPath + "/" + packageDir + "/.gitmodules"
            guard FileManager.default.fileExists(atPath: gitmodulesPath) else {
                continue
            }

            let content: String
            do {
                content = try String(contentsOfFile: gitmodulesPath, encoding: .utf8)
            } catch {
                Self.logger.warning("Cannot read \(gitmodulesPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }

            let submoduleNames = parseSubmoduleNames(from: content)
            let urls = parseSubmoduleURLs(from: content)

            let detail = submoduleNames.isEmpty
                ? "Contains .gitmodules with unknown submodules"
                : "Contains submodules: \(submoduleNames.joined(separator: ", "))"

            let urlContext = urls.isEmpty ? "" : " (URLs: \(urls.joined(separator: ", ")))"
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "SPM dependency '\(packageDir)' has git submodules that may break CI resolution. \(detail)\(urlContext)",
                filePath: gitmodulesPath,
                lineNumber: 1,
                ruleId: "dep-submodule"
            ))

            Self.logger.warning("Submodule found in dependency '\(packageDir, privacy: .public)': \(submoduleNames.joined(separator: ", "), privacy: .public)")
        }

        let elapsed = clock.now - start
        let status: CheckResult.Status = diagnostics.isEmpty ? .passed : .failed
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: elapsed
        )
    }

    func parseSubmoduleNames(from content: String) -> [String] {
        content.lines
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("[submodule \"") else { return nil }
                return trimmed
                    .replacingOccurrences(of: "[submodule \"", with: "")
                    .replacingOccurrences(of: "\"]", with: "")
            }
    }

    func parseSubmoduleURLs(from content: String) -> [String] {
        content.lines
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("url = ") else { return nil }
                return trimmed.replacingOccurrences(of: "url = ", with: "")
            }
    }
}
