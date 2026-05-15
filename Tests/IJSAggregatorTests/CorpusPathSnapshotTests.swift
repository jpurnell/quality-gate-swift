import Testing
import Foundation
@testable import IJSAggregator

@Suite("CorpusPath Snapshot Paths")
struct CorpusPathSnapshotTests {

    private let corpusPath = CorpusPath(basePath: "/corpus", projectID: "my-app")

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    @Test("snapshotDirectory produces correct path for project scope")
    func snapshotDirectoryProject() {
        let dir = corpusPath.snapshotDirectory(scope: "my-app")
        #expect(dir == "/corpus/snapshots/my-app")
    }

    @Test("snapshotDirectory produces correct path for corpus scope")
    func snapshotDirectoryCorpus() {
        let dir = corpusPath.snapshotDirectory(scope: "corpus")
        #expect(dir == "/corpus/snapshots/corpus")
    }

    @Test("snapshotPath produces correct file path")
    func snapshotPath() {
        let path = corpusPath.snapshotPath(scope: "my-app", date: makeDate("2026-04-28"))
        #expect(path == "/corpus/snapshots/my-app/2026-04-28.json")
    }

    @Test("snapshotPath for corpus scope")
    func snapshotPathCorpus() {
        let path = corpusPath.snapshotPath(scope: "corpus", date: makeDate("2026-04-28"))
        #expect(path == "/corpus/snapshots/corpus/2026-04-28.json")
    }

    @Test("snapshotPath uses UTC date formatting")
    func snapshotPathUTC() {
        let path = corpusPath.snapshotPath(scope: "test", date: makeDate("2026-01-01"))
        #expect(path == "/corpus/snapshots/test/2026-01-01.json")
    }
}
