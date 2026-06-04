import Foundation
import SwiftMCPServer
import IJSSensor
import IJSAggregator

struct RecordCalibrationTool: MCPToolHandler, Sendable {
    let corpusPath: String

    let tool = MCPTool(
        name: "ijs_record_calibration",
        description: "Record a JudgmentCalibration when overriding a quality gate finding. Captures root cause, risk tier, adversarial dissent, and a pulse contribution summary.",
        inputSchema: MCPToolInputSchema(
            properties: [
                "project_id": MCPSchemaProperty(
                    type: "string",
                    description: "Project identifier matching the corpus subfolder."
                ),
                "rule_id": MCPSchemaProperty(
                    type: "string",
                    description: "Quality gate rule being overridden (e.g., 'safety.force-unwrap')."
                ),
                "override_rationale": MCPSchemaProperty(
                    type: "string",
                    description: "Why the override is appropriate. Minimum 20 characters."
                ),
                "risk_tier": MCPSchemaProperty(
                    type: "integer",
                    description: "Risk tier 1-4: 1=informational, 2=operational, 3=safety, 4=critical."
                ),
                "proximate_cause": MCPSchemaProperty(
                    type: "string",
                    description: "The specific action or inaction that led to the finding."
                ),
                "root_cause": MCPSchemaProperty(
                    type: "string",
                    description: "Adjective describing the decision process (e.g., 'expedient', 'incomplete')."
                ),
                "failed_step": MCPSchemaProperty(
                    type: "string",
                    description: "Which Dalio 5-Step stage failed.",
                    enum: ["goals", "problems", "diagnosis", "design", "doing"]
                ),
                "red_team_dissent": MCPSchemaProperty(
                    type: "string",
                    description: "Counterargument — why this override might be wrong."
                ),
                "proposed_policy_update": MCPSchemaProperty(
                    type: "string",
                    description: "Suggested rule or guideline change, if any."
                ),
                "engineer": MCPSchemaProperty(
                    type: "string",
                    description: "Engineer who approved the override."
                ),
            ],
            required: [
                "project_id", "rule_id", "override_rationale",
                "risk_tier", "proximate_cause", "root_cause",
                "failed_step", "red_team_dissent",
            ]
        )
    )

    func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
        guard let args = arguments else {
            return .error(message: "Missing required arguments.")
        }

        let projectID = try args.getString("project_id")
        let ruleID = try args.getString("rule_id")
        let rationale = try args.getString("override_rationale")
        let riskTierRaw = try args.getInt("risk_tier")
        let proximateCause = try args.getString("proximate_cause")
        let rootCause = try args.getString("root_cause")
        let failedStepRaw = try args.getString("failed_step")
        let dissent = try args.getString("red_team_dissent")
        let policyUpdate = args.getStringOptional("proposed_policy_update")
        let engineer = args.getStringOptional("engineer") ?? "unknown"

        guard rationale.count >= 20 else {
            return .error(message: "override_rationale must be at least 20 characters (got \(rationale.count)).")
        }

        guard let riskTier = RiskTier(rawValue: riskTierRaw) else {
            return .error(message: "Invalid risk_tier: \(riskTierRaw). Must be 1-4.")
        }

        guard let failedStep = FiveStepStage(rawValue: failedStepRaw) else {
            return .error(message: "Invalid failed_step: '\(failedStepRaw)'. Must be: goals, problems, diagnosis, design, doing.")
        }

        let now = Date()
        let calibration = JudgmentCalibration(
            date: now,
            decisionOwner: engineer,
            practitioner: engineer,
            riskTier: riskTier,
            rootCauseAnalysis: RootCauseAnalysis(
                proximateCause: proximateCause,
                chainOfInquiry: [rationale],
                rootCause: rootCause,
                failedStep: failedStep,
                isRecurringPattern: false
            ),
            redTeamDissent: dissent,
            proposedPolicyUpdate: policyUpdate,
            pulseContribution: "Override of \(ruleID) at tier \(riskTierRaw): \(rationale)"
        )

        let corpus = CorpusPath(basePath: corpusPath, projectID: projectID)
        let writer = TelemetryWriter()

        let emptyMetadata = CheckResultMetadata(
            projectID: projectID,
            timestamp: now,
            environment: .local,
            decisionOwner: engineer,
            results: [],
            overrides: [],
            riskTier: riskTier,
            ethicalFlags: [],
            consistencyScore: nil
        )

        try await writer.write(metadata: emptyMetadata, calibrations: [calibration], to: corpus)

        return .success(text: """
            Calibration recorded.
            Project: \(projectID)
            Rule: \(ruleID)
            Risk tier: \(riskTierRaw) (\(riskTier))
            Failed step: \(failedStep.rawValue)
            Written to: \(corpus.projectDirectory)
            """)
    }
}
