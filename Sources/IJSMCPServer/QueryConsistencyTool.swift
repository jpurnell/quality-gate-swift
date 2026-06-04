import Foundation
import SwiftMCPServer
import IJSDashboardCore
import IJSSensor
import IJSPolicyDiscovery
import IJSAggregator

struct QueryConsistencyTool: MCPToolHandler, Sendable {
    let corpusPath: String

    let tool = MCPTool(
        name: "ijs_query_consistency",
        description: "Check a project's consistency score and retrieve the specific findings driving it down.",
        inputSchema: MCPToolInputSchema(
            properties: [
                "project_id": MCPSchemaProperty(
                    type: "string",
                    description: "Project identifier matching the corpus subfolder."
                ),
                "threshold": MCPSchemaProperty(
                    type: "number",
                    description: "Minimum acceptable consistency score (0.0-1.0). Default: 0.75."
                ),
                "max_findings": MCPSchemaProperty(
                    type: "integer",
                    description: "Maximum findings to return. Default: 20."
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
        let threshold = args.getDoubleOptional("threshold") ?? 0.75
        let maxFindings = args.getIntOptional("max_findings") ?? 20

        let reader = CorpusReader(corpusPath: corpusPath)

        guard let pulse = reader.loadLatestPulse() else {
            return .success(text: "No pulse available — consistency scoring requires at least one Institutional Pulse.")
        }

        let runs = try reader.loadRuns(for: projectID)
        guard let latestRun = runs.last else {
            return .success(text: "No telemetry runs found for project '\(projectID)'.")
        }

        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let report = await auditor.audit(metadata: latestRun.metadata, against: pulse)

        let truncatedFindings = Array(report.findings.prefix(maxFindings))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        struct Response: Codable {
            let projectID: String
            let consistencyScore: Double
            let baselineValidity: String
            let pulseWeekLabel: String
            let passed: Bool
            let threshold: Double
            let totalFindings: Int
            let findings: [FindingResponse]
        }

        struct FindingResponse: Codable {
            let ruleId: String
            let checkerId: String
            let matchType: String
            let historicalOccurrences: Int
            let isRecurring: Bool
            let explanation: String
        }

        let response = Response(
            projectID: projectID,
            consistencyScore: report.consistencyScore,
            baselineValidity: report.baselineValidity.rawValue,
            pulseWeekLabel: report.pulseWeekLabel,
            passed: report.consistencyScore >= threshold,
            threshold: threshold,
            totalFindings: report.findings.count,
            findings: truncatedFindings.map { f in
                FindingResponse(
                    ruleId: f.ruleId,
                    checkerId: f.checkerId,
                    matchType: f.matchType.rawValue,
                    historicalOccurrences: f.historicalOccurrences,
                    isRecurring: f.isRecurringInPulse,
                    explanation: f.explanation
                )
            }
        )

        let data = try encoder.encode(response)
        guard let json = String(data: data, encoding: .utf8) else {
            return .error(message: "Failed to encode consistency report.")
        }

        return .success(text: json)
    }
}
