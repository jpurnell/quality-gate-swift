import Foundation
import SwiftMCPServer

let corpusPath = ProcessInfo.processInfo.environment["IJS_CORPUS_PATH"]
    ?? CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") })

guard let corpusPath else {
    FileHandle.standardError.write(Data("Error: Set IJS_CORPUS_PATH or pass corpus path as argument.\n".utf8))
    exit(1)
}

try await MCPServer.builder()
    .serverName("IJS MCP Server")
    .serverVersion("1.0.0")
    .serverInstructions("""
        Institutional Judgment System tools for querying quality gate \
        telemetry, recording calibrations, and checking consistency.

        **Tools**:
        - ijs_query_pulse: Read the latest Institutional Pulse
        - ijs_record_calibration: Record a judgment calibration for an override
        - ijs_query_consistency: Check a project's consistency score
        - ijs_list_overrides: List recent calibrations
        """)
    .tools(allToolHandlers(corpusPath: corpusPath))
    .run()
