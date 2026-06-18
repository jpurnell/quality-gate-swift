import Foundation
import os
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
/// let auditor = SubmoduleAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
public struct SubmoduleAuditor: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "SubmoduleAuditor")

    /// Unique identifier for this checker.
    public let id = "submodule-audit"

    /// Human-readable name for display.
    public let name = "Submodule Auditor"

    /// Creates a new SubmoduleAuditor instance.
    public init() {}

    /// Run the submodule audit against `.build/checkouts`.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let clock = ContinuousClock()
        let start = clock.now

        let projectRoot = FileManager.default.currentDirectoryPath
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
        content.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("[submodule \"") else { return nil }
                return trimmed
                    .replacingOccurrences(of: "[submodule \"", with: "")
                    .replacingOccurrences(of: "\"]", with: "")
            }
    }

    func parseSubmoduleURLs(from content: String) -> [String] {
        content.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("url = ") else { return nil }
                return trimmed.replacingOccurrences(of: "url = ", with: "")
            }
    }
}
