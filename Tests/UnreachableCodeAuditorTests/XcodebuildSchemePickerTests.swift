import Foundation
import Testing
@testable import UnreachableCodeAuditor

@Suite("xcodebuild scheme picker")
struct XcodebuildSchemePickerTests {

    @Test("Picks first scheme from project listing")
    func projectListing() throws {
        let json = #"""
        {
          "project": {
            "name": "MyApp",
            "schemes": ["MyApp", "MyApp Tests", "Helper"]
          }
        }
        """#.data(using: .utf8)!
        let scheme = try IndexStoreManager.firstScheme(fromXcodebuildListJSON: json)
        #expect(scheme == "MyApp")
    }

    @Test("Picks first scheme from workspace listing")
    func workspaceListing() throws {
        let json = #"""
        {
          "workspace": {
            "name": "MyWorkspace",
            "schemes": ["AppA", "AppB"]
          }
        }
        """#.data(using: .utf8)!
        let scheme = try IndexStoreManager.firstScheme(fromXcodebuildListJSON: json)
        #expect(scheme == "AppA")
    }

    @Test("Throws when no schemes")
    func noSchemes() {
        let json = #"{"project": {"name": "X", "schemes": []}}"#.data(using: .utf8)!
        #expect(throws: Swift.Error.self) {
            _ = try IndexStoreManager.firstScheme(fromXcodebuildListJSON: json)
        }
    }

    @Test("Throws on malformed JSON")
    func malformed() {
        let json = "garbage".data(using: .utf8)!
        #expect(throws: Swift.Error.self) {
            _ = try IndexStoreManager.firstScheme(fromXcodebuildListJSON: json)
        }
    }
}
