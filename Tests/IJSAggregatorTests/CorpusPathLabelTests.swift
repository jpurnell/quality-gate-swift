import Testing
import Foundation
@testable import IJSAggregator

@Suite("CorpusPath Label-Based Paths")
struct CorpusPathLabelTests {

    private let corpusPath = CorpusPath(basePath: "/corpus", projectID: "my-app")

    // MARK: - label: overloads

    @Test("pulsePath(label:) produces correct path with date label")
    func pulsePathWithDateLabel() {
        let path = corpusPath.pulsePath(label: "2026-06-05")
        #expect(path == "/corpus/pulse/2026-06-05/PULSE_2026-06-05.json")
    }

    @Test("pulsePath(label:) produces correct path with week label")
    func pulsePathWithWeekLabel() {
        let path = corpusPath.pulsePath(label: "2026-W22")
        #expect(path == "/corpus/pulse/2026-W22/PULSE_2026-W22.json")
    }

    @Test("pulseDirectory(label:) produces correct directory path")
    func pulseDirectoryWithLabel() {
        let dir = corpusPath.pulseDirectory(label: "2026-06-05")
        #expect(dir == "/corpus/pulse/2026-06-05")
    }

    // MARK: - Backward compatibility

    @Test("pulsePath(weekLabel:) still works identically")
    func pulsePathWeekLabelBackwardCompat() {
        let weekResult = corpusPath.pulsePath(weekLabel: "2026-W22")
        let labelResult = corpusPath.pulsePath(label: "2026-W22")
        #expect(weekResult == labelResult)
        #expect(weekResult == "/corpus/pulse/2026-W22/PULSE_2026-W22.json")
    }

    @Test("pulseDirectory(weekLabel:) still works identically")
    func pulseDirectoryWeekLabelBackwardCompat() {
        let weekResult = corpusPath.pulseDirectory(weekLabel: "2026-W22")
        let labelResult = corpusPath.pulseDirectory(label: "2026-W22")
        #expect(weekResult == labelResult)
        #expect(weekResult == "/corpus/pulse/2026-W22")
    }
}
