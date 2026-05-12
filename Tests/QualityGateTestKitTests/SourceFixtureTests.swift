import Foundation
import Testing
@testable import QualityGateTestKit

/// Tests that source fixtures are well-formed.
///
/// These tests verify the fixture constants contain expected content,
/// ensuring they remain useful as test inputs across auditor test suites.
@Suite("SourceFixture Tests")
struct SourceFixtureTests {

    @Test("minimalValid is not empty")
    func minimalValidNotEmpty() {
        #expect(!SourceFixtures.minimalValid.isEmpty)
    }

    @Test("minimalValid contains a struct definition")
    func minimalValidContainsStruct() {
        #expect(SourceFixtures.minimalValid.contains("struct"))
    }

    @Test("empty is empty")
    func emptyIsEmpty() {
        #expect(SourceFixtures.empty.isEmpty)
    }

    @Test("forceUnwrapPatterns contains force unwrap operator")
    func forceUnwrapPatternsContainsBang() {
        #expect(SourceFixtures.forceUnwrapPatterns.contains("!"))
    }

    @Test("forceUnwrapPatterns contains force cast")
    func forceUnwrapPatternsContainsForceCast() {
        #expect(SourceFixtures.forceUnwrapPatterns.contains("as!"))
    }

    @Test("classWithDeinit is not empty")
    func classWithDeinitNotEmpty() {
        #expect(!SourceFixtures.classWithDeinit.isEmpty)
    }

    @Test("classWithDeinit contains deinit")
    func classWithDeinitContainsDeinit() {
        #expect(SourceFixtures.classWithDeinit.contains("deinit"))
    }

    @Test("basicActor contains actor keyword")
    func basicActorContainsActor() {
        #expect(SourceFixtures.basicActor.contains("actor"))
    }
}
