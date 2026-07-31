import ArgumentParser
import ControlMapping
import Foundation
import QualityGateCore

/// `quality-gate compliance` — the honest control-coverage report
/// (RegulatoryControlMapping Phase 1).
///
/// Renders the SOC 2 / ISO 27001 / HIPAA technical-control coverage matrix from
/// the bundled mapping: which controls a rule enforces, which the gate's own
/// operation evidences, and which are out of scope for static analysis. It
/// reports coverage, never compliance — the disclaimer leads every rendering.
struct Compliance: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compliance",
        abstract: "Report technical-control coverage (SOC2/ISO/HIPAA): enforced, evidence-only, out-of-scope. NOT an assertion of compliance."
    )

    /// `--as` (not `--format`): the root command owns `--format`, and ArgumentParser
    /// lets a parent option shadow a same-named child one after the subcommand name.
    @Option(name: .customLong("as"), help: "Output format: terminal (default) or json")
    var outputAs: String = "terminal"

    func run() throws {
        guard let reportFormat = ComplianceReportFormat(rawValue: outputAs) else {
            print("ERROR: unknown format '\(outputAs)'. Use 'terminal' or 'json'.")
            throw ExitCode(1)
        }
        let matrix = ComplianceCoverage.matrix(
            catalogs: ControlMappingResources.catalogs(),
            mappings: ControlMappingResources.mappings(),
            knownRuleIds: ControlMappingResources.registryRuleIds())
        print(ComplianceReport.render(matrix, format: reportFormat))
    }
}
