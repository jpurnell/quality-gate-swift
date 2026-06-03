import Foundation
import Testing
@testable import IndexStoreInfra

@Suite("IndexStoreSession")
struct IndexStoreSessionTests {

    @Test("findLibIndexStore returns a valid path on macOS")
    func findsLibIndexStore() throws {
        let path = try #require(IndexStoreSession.findLibIndexStore())
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
}
