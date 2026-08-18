import Foundation
import Testing
@testable import UnreachableCodeAuditor

@Suite("xcodebuild scheme picker")
struct XcodebuildSchemePickerTests {

    @Test("Picks first scheme from project listing")
    func projectListing() throws {
        let json = Data(#"""
        {
          "project": {
            "name": "MyApp",
            "schemes": ["MyApp", "MyApp Tests", "Helper"]
          }
        }
        """#.utf8)
        let scheme = try IndexStoreManager.firstScheme(fromXcodebuildListJSON: json)
        #expect(scheme == "MyApp")
    }

    @Test("Picks first scheme from workspace listing")
    func workspaceListing() throws {
        let json = Data(#"""
        {
          "workspace": {
            "name": "MyWorkspace",
            "schemes": ["AppA", "AppB"]
          }
        }
        """#.utf8)
        let scheme = try IndexStoreManager.firstScheme(fromXcodebuildListJSON: json)
        #expect(scheme == "AppA")
    }

    @Test("Throws when no schemes")
    func noSchemes() {
        let json = Data(#"{"project": {"name": "X", "schemes": []}}"#.utf8)
        #expect(throws: Swift.Error.self) {
            _ = try IndexStoreManager.firstScheme(fromXcodebuildListJSON: json)
        }
    }

    @Test("Throws on malformed JSON")
    func malformed() {
        let json = Data("garbage".utf8)
        #expect(throws: Swift.Error.self) {
            _ = try IndexStoreManager.firstScheme(fromXcodebuildListJSON: json)
        }
    }
}
