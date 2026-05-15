import Testing
import Foundation
@testable import IJSAggregator

@Suite("CorpusPath Pulse Paths")
struct CorpusPathPulseTests {

    private let corpusPath = CorpusPath(basePath: "/corpus", projectID: "my-app")

    @Test("pulseDirectory produces correct path")
    func pulseDirectory() {
        let dir = corpusPath.pulseDirectory(weekLabel: "2026-W18")
        #expect(dir == "/corpus/pulse/2026-W18")
    }

    @Test("pulsePath produces correct file path")
    func pulsePath() {
        let path = corpusPath.pulsePath(weekLabel: "2026-W18")
        #expect(path == "/corpus/pulse/2026-W18/PULSE_2026-W18.json")
    }

    @Test("pulseRoot produces correct root directory")
    func pulseRoot() {
        #expect(corpusPath.pulseRoot == "/corpus/pulse")
    }

    @Test("pulseDirectory with different week labels")
    func pulseDirectoryVariant() {
        let dir = corpusPath.pulseDirectory(weekLabel: "2025-W01")
        #expect(dir == "/corpus/pulse/2025-W01")
    }

    @Test("pulsePath is independent of projectID")
    func pulsePathIndependentOfProject() {
        let other = CorpusPath(basePath: "/corpus", projectID: "other-app")
        #expect(corpusPath.pulsePath(weekLabel: "2026-W18") == other.pulsePath(weekLabel: "2026-W18"))
    }
}
