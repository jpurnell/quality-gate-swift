import Foundation
import QualityGateCore

/// The gate adapter for one configured Tier-2 plugin (Phase 4b).
///
/// Trust rules, applied here and nowhere else:
/// - **Advisory by default**: unless the entry declares `gates: true`, every
///   plugin finding is downgraded to a note and the verdict to passed — a
///   plugin cannot fail the gate until the user explicitly says it may.
/// - **Provenance always**: every diagnostic carries
///   `origin: plugin/<name>` into reports and telemetry.
/// - **Failure is a finding, not a crash**: timeout, non-zero exit,
///   malformed output, missing executable, and unknown contract versions
///   each produce a `plugin-error` (or skip) diagnostic.
public struct PluginChecker: QualityChecker, Sendable {
    /// The configured plugin entry.
    public let plugin: PluginConfig

    /// Checker identifier: the plugin's configured name.
    public var id: String { plugin.name }
    /// Display name.
    public var name: String { "Plugin: \(plugin.name)" }

    /// Creates the adapter for one plugin entry.
    public init(plugin: PluginConfig) {
        self.plugin = plugin
    }

    /// Runs the plugin per the contract and applies the trust rules.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        guard let executable = PluginRunner.resolveExecutable(for: plugin) else {
            return errorResult(
                "plugin executable not found (run: \(plugin.run ?? "quality-gate-plugin-\(plugin.name) on PATH"))",
                since: startTime)
        }
        guard let descriptor = PluginRunner.describe(executable: executable) else {
            return errorResult(
                "plugin handshake failed — `\(executable) contract` did not produce a descriptor",
                since: startTime)
        }
        guard descriptor.contractVersion <= PluginContract.currentVersion else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [Diagnostic(
                    severity: .note,
                    message: "plugin speaks contract v\(descriptor.contractVersion); this gate speaks v\(PluginContract.currentVersion) — skipped, not guessed",
                    ruleId: "plugin-error",
                    origin: originTag)],
                duration: ContinuousClock.now - startTime)
        }

        let request = PluginCheckRequest(
            projectRoot: FileManager.default.currentDirectoryPath,
            config: plugin.config)
        let outcome = PluginRunner.check(
            executable: executable, request: request,
            timeoutSeconds: plugin.timeoutSeconds)

        switch outcome {
        case .timedOut(let seconds):
            return errorResult("plugin exceeded its \(seconds)s budget and was terminated", since: startTime)
        case .failed(let exitCode, let output):
            return errorResult(
                "plugin exited \(exitCode): \(output.prefix(300))", since: startTime)
        case .launchFailed(let reason):
            return errorResult("plugin launch failed: \(reason)", since: startTime)
        case .responded(let data):
            guard let response = try? JSONDecoder().decode(CheckResult.self, from: data) else {
                return errorResult(
                    "plugin output was not a CheckResult: \(String(decoding: data.prefix(200), as: UTF8.self))",
                    since: startTime)
            }
            return applyTrust(to: response, since: startTime)
        }
    }

    /// Origin tag stamped on every diagnostic from this plugin.
    private var originTag: String { "plugin/\(plugin.name)" }

    /// Stamps provenance and enforces advisory-by-default.
    private func applyTrust(to response: CheckResult, since startTime: ContinuousClock.Instant) -> CheckResult {
        let stamped = CheckResult(
            checkerId: id,
            status: response.status,
            diagnostics: response.diagnostics.map { diagnostic in
                Diagnostic(
                    severity: diagnostic.severity,
                    message: diagnostic.message,
                    filePath: diagnostic.filePath,
                    lineNumber: diagnostic.lineNumber,
                    columnNumber: diagnostic.columnNumber,
                    ruleId: diagnostic.ruleId,
                    suggestedFix: diagnostic.suggestedFix,
                    origin: originTag)
            },
            overrides: response.overrides,
            complianceRecords: response.complianceRecords,
            duration: ContinuousClock.now - startTime)
        guard plugin.gates else {
            // Advisory: findings fully visible, nothing gates. One transform,
            // shared with trial mode.
            return AdvisoryDowngrade.apply(to: [stamped])[0]
        }
        return stamped
    }

    /// A `plugin-error` result. Severity follows the trust rule: an
    /// advisory plugin's failure is a note; a gating plugin's failure is an
    /// error (if it may fail the gate, its absence must too).
    private func errorResult(_ message: String, since startTime: ContinuousClock.Instant) -> CheckResult {
        CheckResult(
            checkerId: id,
            status: plugin.gates ? .failed : .passed,
            diagnostics: [Diagnostic(
                severity: plugin.gates ? .error : .note,
                message: message,
                ruleId: "plugin-error",
                origin: originTag)],
            duration: ContinuousClock.now - startTime)
    }
}
