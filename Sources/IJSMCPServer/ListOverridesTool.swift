import Foundation
import os
import SwiftMCPServer
import IJSSensor
import IJSAggregator

private let logger = Logger(subsystem: "com.quality-gate.ijs-mcp", category: "ListOverridesTool")

struct ListOverridesTool: MCPToolHandler, Sendable {
    let corpusPath: String

    let tool = MCPTool(
        name: "ijs_list_overrides",
        description: "List recent JudgmentCalibrations for a project, sorted by date (most recent first). Useful for code review context.",
        inputSchema: MCPToolInputSchema(
            properties: [
                "project_id": MCPSchemaProperty(
                    type: "string",
                    description: "Project identifier matching the corpus subfolder."
                ),
                "limit": MCPSchemaProperty(
                    type: "integer",
                    description: "Maximum calibrations to return. Default: 10."
                ),
                "risk_tier_min": MCPSchemaProperty(
                    type: "integer",
                    description: "Minimum risk tier to include (1-4). Omit for all tiers."
                ),
                "since_days": MCPSchemaProperty(
                    type: "integer",
                    description: "Only return calibrations from the last N days. Default: 90."
                ),
            ],
            required: ["project_id"]
        )
    )

    func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
        guard let args = arguments else {
            return .error(message: "Missing required argument: project_id.")
        }

        let projectID = try args.getString("project_id")
        let limit = args.getIntOptional("limit") ?? 10
        let riskTierMin = args.getIntOptional("risk_tier_min")
        let sinceDays = args.getIntOptional("since_days") ?? 90

        let corpus = CorpusPath(basePath: corpusPath, projectID: projectID)
        let writer = TelemetryWriter()

        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -sinceDays, to: endDate)
            ?? endDate

        let calibrations: [JudgmentCalibration]
        do {
            calibrations = try await writer.readCalibrations(from: corpus, startDate: startDate, endDate: endDate)
        } catch {
            logger.warning("Failed to read calibrations for \(projectID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let msg = "No calibrations found for project '\(projectID)' in the last \(sinceDays) days."
            return .success(text: msg)
        }

        var filtered = calibrations
        if let minTier = riskTierMin, let tier = RiskTier(rawValue: minTier) {
            filtered = filtered.filter { $0.riskTier >= tier }
        }

        let sorted = filtered.sorted { $0.date > $1.date }
        let truncated = Array(sorted.prefix(limit))

        if truncated.isEmpty {
            return .success(text: "No calibrations found for project '\(projectID)' matching filters.")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        struct Response: Codable {
            let projectID: String
            let totalMatching: Int
            let returned: Int
            let calibrations: [CalibrationResponse]
        }

        struct CalibrationResponse: Codable {
            let date: Date
            let riskTier: Int
            let decisionOwner: String
            let proximateCause: String
            let rootCause: String
            let failedStep: String
            let redTeamDissent: String
            let proposedPolicyUpdate: String?
            let pulseContribution: String
        }

        let response = Response(
            projectID: projectID,
            totalMatching: filtered.count,
            returned: truncated.count,
            calibrations: truncated.map { cal in
                CalibrationResponse(
                    date: cal.date,
                    riskTier: cal.riskTier.rawValue,
                    decisionOwner: cal.decisionOwner,
                    proximateCause: cal.rootCauseAnalysis.proximateCause,
                    rootCause: cal.rootCauseAnalysis.rootCause,
                    failedStep: cal.rootCauseAnalysis.failedStep.rawValue,
                    redTeamDissent: cal.redTeamDissent,
                    proposedPolicyUpdate: cal.proposedPolicyUpdate,
                    pulseContribution: cal.pulseContribution
                )
            }
        )

        let data = try encoder.encode(response)
        guard let json = String(data: data, encoding: .utf8) else {
            return .error(message: "Failed to encode calibrations.")
        }

        return .success(text: json)
    }
}
