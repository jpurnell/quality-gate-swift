import Testing
import Foundation
@testable import IJSAggregator

@Suite("CorpusPath")
struct CorpusPathTests {

    static let basePath = "/tmp/test-corpus"
    static let projectID = "quality-gate-swift"

    static let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: 2026, month: 4, day: 28, hour: 14, minute: 30, second: 22)
        return cal.date(from: comps)!
    }()

    @Test("projectDirectory returns basePath/telemetry/projectID/")
    func projectDirectory() {
        let cp = CorpusPath(basePath: Self.basePath, projectID: Self.projectID)
        #expect(cp.projectDirectory == "/tmp/test-corpus/telemetry/quality-gate-swift")
    }

    @Test("dailyDirectory formats date as YYYY-MM-DD")
    func dailyDirectory() {
        let cp = CorpusPath(basePath: Self.basePath, projectID: Self.projectID)
        let dir = cp.dailyDirectory(for: Self.referenceDate)
        #expect(dir == "/tmp/test-corpus/telemetry/quality-gate-swift/2026-04-28")
    }

    @Test("metadataPath includes HHmmss and _metadata.json suffix")
    func metadataPath() {
        let cp = CorpusPath(basePath: Self.basePath, projectID: Self.projectID)
        let path = cp.metadataPath(for: Self.referenceDate)
        #expect(path == "/tmp/test-corpus/telemetry/quality-gate-swift/2026-04-28/143022_metadata.json")
    }

    @Test("calibrationPath includes HHmmss, index, and _calibration suffix")
    func calibrationPath() {
        let cp = CorpusPath(basePath: Self.basePath, projectID: Self.projectID)
        let path = cp.calibrationPath(for: Self.referenceDate, index: 0)
        #expect(path == "/tmp/test-corpus/telemetry/quality-gate-swift/2026-04-28/143022_calibration_0.json")
    }

    @Test("calibrationPath with index > 0")
    func calibrationPathMultiple() {
        let cp = CorpusPath(basePath: Self.basePath, projectID: Self.projectID)
        let path = cp.calibrationPath(for: Self.referenceDate, index: 3)
        #expect(path == "/tmp/test-corpus/telemetry/quality-gate-swift/2026-04-28/143022_calibration_3.json")
    }

    @Test("Equatable: same inputs produce equal paths")
    func equatable() {
        let a = CorpusPath(basePath: "/corpus", projectID: "app")
        let b = CorpusPath(basePath: "/corpus", projectID: "app")
        #expect(a == b)
    }

    @Test("Equatable: different projectID produces unequal paths")
    func notEqual() {
        let a = CorpusPath(basePath: "/corpus", projectID: "app-a")
        let b = CorpusPath(basePath: "/corpus", projectID: "app-b")
        #expect(a != b)
    }

    @Test("Midnight timestamp produces 000000 filename component")
    func midnightTimestamp() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midnight = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0))!
        let cp = CorpusPath(basePath: "/corpus", projectID: "test")
        let path = cp.metadataPath(for: midnight)
        #expect(path.contains("000000_metadata.json"))
    }

    @Test("Project ID with hyphens is preserved in path")
    func hyphenatedProjectID() {
        let cp = CorpusPath(basePath: "/corpus", projectID: "my-cool-project")
        #expect(cp.projectDirectory == "/corpus/telemetry/my-cool-project")
    }

    @Test("Sendable conformance")
    func sendable() {
        let path: any Sendable = CorpusPath(basePath: "/test", projectID: "test")
        #expect(path is CorpusPath)
    }
}
