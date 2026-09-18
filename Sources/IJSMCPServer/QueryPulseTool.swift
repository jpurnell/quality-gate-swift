import Foundation
import CorpusKit
import SwiftMCPServer
import IJSDashboardCore

struct QueryPulseTool: MCPToolHandler, Sendable {
    let corpusPath: String

    let tool = MCPTool(
        name: "ijs_query_pulse",
        description: "Read the latest Institutional Pulse for a project, including trends, violation clusters, anomalies, and calibration summaries.",
        inputSchema: MCPToolInputSchema(
            properties: [
                "week_label": MCPSchemaProperty(
                    type: "string",
                    description: "ISO week label (e.g., '2026-W22'). Omit for latest."
                ),
            ]
        )
    )

    func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
        let reader = CorpusReader(corpusPath: corpusPath)

        let pulse: InstitutionalPulse?
        if let weekLabel = arguments?.getStringOptional("week_label") {
            // `loadPulse(label:)` returns nil for a non-component label, which reads as "no
            // such pulse". Saying so here distinguishes a bad label from a missing one.
            guard CorpusPath.isSingleComponent(weekLabel) else {
                return .error(message: "week_label '\(weekLabel)' is not a pulse label.")
            }
            pulse = reader.loadPulse(weekLabel: weekLabel)
        } else {
            pulse = reader.loadLatestPulse()
        }

        guard let pulse else {
            let weeks = reader.listAvailableWeeks()
            if weeks.isEmpty {
                return .success(text: "No pulse data found in corpus at \(corpusPath).")
            }
            return .success(text: "No pulse found for requested week. Available: \(weeks.joined(separator: ", "))")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(pulse)
        guard let json = String(data: data, encoding: .utf8) else {
            return .error(message: "Failed to encode pulse as JSON.")
        }

        return .success(text: json)
    }
}
