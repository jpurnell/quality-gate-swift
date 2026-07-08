import Foundation
import Testing
@testable import LegibilityAnalyzer

@Suite("LegibilityIndexPass helpers")
struct LegibilityIndexPassTests {

    @Test("module name is extracted from a Sources path")
    func moduleFromSources() {
        #expect(LegibilityIndexPass.moduleName(fromFilePath: "/repo/Sources/Core/File.swift") == "Core")
        #expect(LegibilityIndexPass.moduleName(fromFilePath: "/repo/Sources/Core/Sub/File.swift") == "Core")
    }

    @Test("module name is extracted from a Tests path")
    func moduleFromTests() {
        #expect(LegibilityIndexPass.moduleName(fromFilePath: "/repo/Tests/CoreTests/File.swift") == "CoreTests")
    }

    @Test("a path with neither segment yields nil")
    func noModule() {
        #expect(LegibilityIndexPass.moduleName(fromFilePath: "/repo/other/File.swift") == nil)
    }

    @Test("test modules are recognized by suffix")
    func testModuleDetection() {
        #expect(LegibilityIndexPass.isTestModule("CoreTests"))
        #expect(!LegibilityIndexPass.isTestModule("Core"))
    }
}

@Suite("LegibilityAnalyzer static helpers")
struct LegibilityAnalyzerHelperTests {

    @Test("filterExempt drops exempt modules and edges into them")
    func filterExempt() {
        let graph = ModuleGraph(edges: ["A": ["Core", "Gen"], "Gen": ["Core"]])
        let filtered = LegibilityAnalyzer.filterExempt(graph, exemptModules: ["Gen"])
        #expect(!filtered.modules.contains("Gen"))
        #expect(filtered.dependencies(of: "A") == ["Core"])
    }

    @Test("countByModule counts only unacknowledged occurrences")
    func countByModule() {
        let occ = [
            OverPublicOccurrence(symbolName: "a", moduleName: "M", filePath: "/f", line: 1, acknowledged: false),
            OverPublicOccurrence(symbolName: "b", moduleName: "M", filePath: "/f", line: 2, acknowledged: false),
            OverPublicOccurrence(symbolName: "c", moduleName: "M", filePath: "/f", line: 3, acknowledged: true),
            OverPublicOccurrence(symbolName: "d", moduleName: "N", filePath: "/g", line: 1, acknowledged: false),
        ]
        let counts = LegibilityAnalyzer.countByModule(occ)
        #expect(counts["M"] == 2)   // acknowledged 'c' excluded
        #expect(counts["N"] == 1)
    }
}
