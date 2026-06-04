import SwiftMCPServer

func allToolHandlers(corpusPath: String) -> [any MCPToolHandler] {
    [
        QueryPulseTool(corpusPath: corpusPath),
        RecordCalibrationTool(corpusPath: corpusPath),
        QueryConsistencyTool(corpusPath: corpusPath),
        ListOverridesTool(corpusPath: corpusPath),
    ]
}
