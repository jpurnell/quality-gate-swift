import Foundation
import Testing
@testable import QualityGateCore

// SwiftKeychain puts its adapters behind package traits that are off by default, and a
// trait-gated dependency is not even resolved while its trait is off. The gate had no way
// to turn one on, so `build`, `test`, the index and DocC compiled a package with those
// adapters missing, and reported on the part that was left.

@Suite("traits: the SwiftPM package traits every build is run with")
struct PackageTraitsConfigTests {

    @Test("An absent key enables no traits and passes nothing to SwiftPM")
    func absentKeyIsEmpty() throws {
        let configuration = try Configuration.from(yaml: "enabledCheckers: []\n")
        #expect(configuration.traits.isEmpty)
        #expect(configuration.unknownKeys == nil)
        #expect(PackageTraits.arguments(enabling: configuration.traits).isEmpty)
        #expect(Configuration().traits.isEmpty)
    }

    @Test("A list of traits is read in the order written, and is a known key")
    func traitsAreRead() throws {
        let configuration = try Configuration.from(yaml: "traits: [OAuth, CLIAuth]\n")
        #expect(configuration.traits == ["OAuth", "CLIAuth"])
        #expect(configuration.unknownKeys == nil)
    }

    @Test("An empty list is the same as no key at all")
    func emptyListIsAbsent() throws {
        let configuration = try Configuration.from(yaml: "traits: []\n")
        #expect(configuration.traits.isEmpty)
        #expect(configuration.unknownKeys == nil)
        #expect(PackageTraits.arguments(enabling: configuration.traits).isEmpty)
    }

    @Test("Traits become one comma-separated --traits argument, as SwiftPM spells it")
    func argumentsAreCommaSeparated() {
        #expect(PackageTraits.arguments(enabling: ["OAuth", "CLIAuth"]) == ["--traits", "OAuth,CLIAuth"])
        #expect(PackageTraits.arguments(enabling: ["defaults", "OAuth"]) == ["--traits", "defaults,OAuth"])
        #expect(PackageTraits.arguments(enabling: []) == [])
    }

    @Test("A name SwiftPM would split or could not parse is refused, naming the key", arguments: [
        "\"\"", "\"OAuth,CLIAuth\"", "\"O Auth\"",
    ])
    func malformedNameIsRefused(written: String) {
        let error = #expect(throws: QualityGateError.self) {
            try Configuration.from(yaml: "traits: [\(written)]\n")
        }
        guard case .configurationError(let message)? = error else {
            Issue.record("expected a configuration error, got \(String(describing: error))")
            return
        }
        #expect(message.contains("`traits"))
    }

    @Test("Changing the traits changes the configuration salt, so no cached verdict crosses them")
    func traitsReachTheCacheSalt() {
        var withTraits = Configuration()
        withTraits.traits = ["OAuth"]
        #expect(CheckerFingerprint.canonicalSalt(withTraits) != CheckerFingerprint.canonicalSalt(Configuration()))
    }
}
