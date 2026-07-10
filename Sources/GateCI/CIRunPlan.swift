import Foundation

/// The canonical CI invocation of the quality gate (Phase 2).
///
/// `quality-gate ci` builds this plan and re-enters the standard run path
/// with these arguments, so local hook, local manual run, and CI run cannot
/// drift by construction. The plan is the determinism contract: every input
/// that can differ between two runs of the same commit is forced to a
/// declared state — index use is deliberate (off unless opted in), the
/// result cache is off (correct before fast), the timezone is UTC, and
/// machine-readable outputs are always produced.
public struct CIRunPlan: Sendable, Equatable {
    /// How the run treats the semantic index.
    public enum IndexMode: String, Sendable {
        /// Never build an index; reuse none — the default. Eliminates the
        /// largest local-vs-CI variance source ("whichever index was lying
        /// around").
        case none
        /// The workflow explicitly opted into building an index first.
        case build
    }

    /// The run's index policy.
    public let indexMode: IndexMode
    /// Directory receiving the SARIF and JSON summary artifacts.
    public let outputDirectory: String
    /// Whether warnings fail the run (the org default is yes).
    public let strict: Bool

    /// Creates a plan.
    ///
    /// - Parameters:
    ///   - indexMode: Index policy; defaults to ``IndexMode/none``.
    ///   - outputDirectory: Artifact directory; defaults to `.quality-gate-ci`.
    ///   - strict: Warnings fail the run; defaults to true.
    public init(
        indexMode: IndexMode = .none,
        outputDirectory: String = ".quality-gate-ci",
        strict: Bool = true
    ) {
        self.indexMode = indexMode
        self.outputDirectory = outputDirectory
        self.strict = strict
    }

    /// Path of the SARIF artifact this plan produces.
    public var sarifOutputPath: String {
        (outputDirectory as NSString).appendingPathComponent("quality-gate.sarif")
    }

    /// Path of the JSON summary artifact this plan produces.
    public var summaryOutputPath: String {
        (outputDirectory as NSString).appendingPathComponent("quality-gate-summary.json")
    }

    /// The canonical gate arguments — one entrypoint, three callers.
    public var gateArguments: [String] {
        var arguments: [String] = []
        if indexMode == .none {
            arguments.append("--no-index-build")
        }
        arguments.append("--no-cache")
        if strict {
            arguments.append("--strict")
        }
        arguments.append("--continue-on-failure")
        arguments.append(contentsOf: ["--sarif-output", sarifOutputPath])
        arguments.append(contentsOf: ["--summary-output", summaryOutputPath])
        return arguments
    }

    /// Environment forced to a declared state for the run.
    public var environmentOverrides: [String: String] {
        ["TZ": "UTC"]
    }
}
