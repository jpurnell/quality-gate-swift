import Foundation
import Testing
import Yams
@testable import QualityGateCore

/// The `boundedIO:` block, and whose kernel the rule is about.
///
/// `Configuration` decodes with `decodeIfPresent(…) ?? default`, so a key the schema does not
/// define is discarded silently and nothing downstream can tell it was written. That is how the
/// `ijs:` block went unread, and it is the failure mode a new configuration section is most
/// likely to ship with — the checker reads its default, the run looks correct, and the setting
/// the user wrote had no effect.
@Suite("bounded-io configuration")
struct BoundedIOConfigTests {

    private func decode(_ yaml: String) throws -> Configuration {
        try YAMLDecoder().decode(Configuration.self, from: yaml)
    }

    @Test("the boundedIO block decodes instead of being discarded")
    func blockIsDecoded() throws {
        let config = try decode("""
        boundedIO:
          kernelPath: Sources/CoverLetterWriterLib/ProcessRunner.swift
        """)
        #expect(config.boundedIO.kernelPath == "Sources/CoverLetterWriterLib/ProcessRunner.swift")
    }

    /// Absent means "this package's own kernel", not "no kernel".
    @Test("an absent block leaves the kernel unset, and the checker supplies its default")
    func absentBlockIsNil() throws {
        let config = try decode("strict: true\n")
        #expect(config.boundedIO.kernelPath == nil)
    }

    /// The value must survive a round trip, or a cache salt computed from the configuration
    /// would not see it and two different kernels would share one fingerprint.
    @Test("the kernel path round-trips through encoding")
    func roundTrips() throws {
        var config = Configuration()
        config.boundedIO.kernelPath = "Sources/Foo/MyRunner.swift"
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Configuration.self, from: encoded)
        #expect(decoded.boundedIO.kernelPath == "Sources/Foo/MyRunner.swift")
    }
}
