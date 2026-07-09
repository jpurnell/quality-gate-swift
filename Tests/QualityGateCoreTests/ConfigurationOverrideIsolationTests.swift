import Foundation
import Testing
@testable import QualityGateCore

/// Phase 0, workstream 0.2 — override isolation.
///
/// Applying any single CLI override must change exactly its own field and
/// preserve every other section byte-for-byte. The fixture sets **every**
/// configuration section non-default, so a memberwise-reconstruction bug
/// (a section silently reverting to `.default`) cannot hide: the reverted
/// section differs from the baseline and is named in the failure message.
@Suite("Configuration override isolation")
struct ConfigurationOverrideIsolationTests {

    /// Every section carries at least one non-default value.
    private static let fixtureYAML = """
    parallelWorkers: 3
    excludePatterns: ["FixtureExcluded/"]
    vendorPaths: ["FixtureVendor/"]
    safetyExemptions: ["fixtureExemption"]
    enabledCheckers: ["build"]
    buildConfiguration: "release"
    testFilter: "FixtureFilter"
    docTarget: "FixtureDoc"
    docCoverageThreshold: 55
    unreachableAutoBuildXcode: false
    xcodeScheme: "FixtureScheme"
    xcodeDestination: "platform=macOS"
    recursion:
      useIndexStore: false
    concurrency:
      justificationKeyword: "FixtureJustification"
    pointerEscape:
      allowedEscapeFunctions: ["fixtureEscape"]
    security:
      enabledRules: ["fixture-rule"]
    status:
      guidelinesPath: "fixture-guidelines"
    swiftVersion:
      minimum: "9.9"
    memoryBuilder:
      guidelinesPath: "fixture-memory-guidelines"
    logging:
      exemptFiles: ["FixtureLogging.swift"]
    dependencyAudit:
      maxMajorVersionsBehind: 7
    submoduleAudit:
      allowedPackages: ["fixture-package"]
    releaseReadiness:
      changelogPath: "FIXTURE_CHANGELOG.md"
    fpSafety:
      allowedFiles: ["FixtureFP.swift"]
    stochasticDeterminism:
      exemptFunctions: ["fixtureRandom"]
    temporalDeterminism:
      exemptTypes: ["FixtureClock"]
    flipDetector:
      strict: true
    stress:
      runs: 4
    memoryLifecycle:
      delegatePatterns: ["fixtureDelegate"]
    mcpReadiness:
      exemptFiles: ["FixtureMCP.swift"]
    appIntentsReadiness:
      exemptFiles: ["FixtureIntents.swift"]
    build:
      solverExpressionTimeThreshold: 999
    xcodeBuild:
      project: "Fixture.xcodeproj"
    consistency:
      corpusPath: "/tmp/fixture-corpus"
      projectID: "FixtureProject"
    complexity:
      cognitiveThreshold: 7
      crossModuleMaxDepth: 3
    legibility:
      useIndexStore: false
      minFanInForCentral: 9
    docCoverage:
      useIndexStore: false
    overrides:
      "safety.fixture-rule": "warning"
    """

    /// Loads the fixture through the same path the CLI uses.
    private func loadFixture() throws -> Configuration {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("override-isolation-\(UUID().uuidString).yml").path
        try Self.fixtureYAML.write(toFile: path, atomically: true, encoding: .utf8)
        return try Configuration.load(from: path)
    }

    /// Section-by-section comparison; returns the names of sections that differ.
    private func differingSections(_ a: Configuration, _ b: Configuration) -> [String] {
        var diffs: [String] = []
        func check(_ name: String, _ equal: Bool) { if !equal { diffs.append(name) } }
        check("parallelWorkers", a.parallelWorkers == b.parallelWorkers)
        check("excludePatterns", a.excludePatterns == b.excludePatterns)
        check("vendorPaths", a.vendorPaths == b.vendorPaths)
        check("safetyExemptions", a.safetyExemptions == b.safetyExemptions)
        check("enabledCheckers", a.enabledCheckers == b.enabledCheckers)
        check("buildConfiguration", a.buildConfiguration == b.buildConfiguration)
        check("testFilter", a.testFilter == b.testFilter)
        check("docTarget", a.docTarget == b.docTarget)
        check("docCoverageThreshold", a.docCoverageThreshold == b.docCoverageThreshold)
        check("unreachableAutoBuildXcode", a.unreachableAutoBuildXcode == b.unreachableAutoBuildXcode)
        check("xcodeScheme", a.xcodeScheme == b.xcodeScheme)
        check("xcodeDestination", a.xcodeDestination == b.xcodeDestination)
        check("recursion", a.recursion == b.recursion)
        check("concurrency", a.concurrency == b.concurrency)
        check("pointerEscape", a.pointerEscape == b.pointerEscape)
        check("security", a.security == b.security)
        check("status", a.status == b.status)
        check("swiftVersion", a.swiftVersion == b.swiftVersion)
        check("memoryBuilder", a.memoryBuilder == b.memoryBuilder)
        check("logging", a.logging == b.logging)
        check("dependencyAudit", a.dependencyAudit == b.dependencyAudit)
        check("submoduleAudit", a.submoduleAudit == b.submoduleAudit)
        check("releaseReadiness", a.releaseReadiness == b.releaseReadiness)
        check("fpSafety", a.fpSafety == b.fpSafety)
        check("stochasticDeterminism", a.stochasticDeterminism == b.stochasticDeterminism)
        check("temporalDeterminism", a.temporalDeterminism == b.temporalDeterminism)
        check("flipDetector", a.flipDetector == b.flipDetector)
        check("stress", a.stress == b.stress)
        check("memoryLifecycle", a.memoryLifecycle == b.memoryLifecycle)
        check("mcpReadiness", a.mcpReadiness == b.mcpReadiness)
        check("appIntentsReadiness", a.appIntentsReadiness == b.appIntentsReadiness)
        check("build", a.build == b.build)
        check("xcodeBuild", a.xcodeBuild == b.xcodeBuild)
        check("consistency", a.consistency == b.consistency)
        check("complexity", a.complexity == b.complexity)
        check("legibility", a.legibility == b.legibility)
        check("docCoverage", a.docCoverage == b.docCoverage)
        check("overrides", a.overrides == b.overrides)
        return diffs
    }

    @Test("fixture actually sets every mutable section non-default")
    func fixtureIsNonDefault() throws {
        let baseline = try loadFixture()
        // The sections the overrides can clobber must all differ from defaults,
        // or a revert-to-default bug could hide behind a default-valued section.
        let defaults = Configuration()
        let sameAsDefault = differingSections(baseline, defaults)
        #expect(sameAsDefault.count >= 30, "fixture too weak — only \(sameAsDefault.count) sections non-default")
    }

    @Test("--auto-build-xcode changes exactly unreachableAutoBuildXcode")
    func autoBuildIsolation() throws {
        let baseline = try loadFixture()
        let mutated = baseline.applying(CLIOverrides(autoBuildXcode: true))
        #expect(mutated.unreachableAutoBuildXcode == true)
        #expect(differingSections(baseline, mutated) == ["unreachableAutoBuildXcode"])
    }

    @Test("--threshold changes exactly complexity.cognitiveThreshold")
    func thresholdIsolation() throws {
        let baseline = try loadFixture()
        let mutated = baseline.applying(CLIOverrides(threshold: 42))
        #expect(mutated.complexity.cognitiveThreshold == 42)
        #expect(differingSections(baseline, mutated) == ["complexity"])
        // Within the section, every other field survives — this reproduces the
        // shipped bug (crossModuleMaxDepth reverted to default under override).
        #expect(mutated.complexity.crossModuleMaxDepth == baseline.complexity.crossModuleMaxDepth)
        #expect(mutated.complexity.reportTopN == baseline.complexity.reportTopN)
    }

    @Test("--telemetry-corpus-path changes exactly consistency.corpusPath")
    func corpusPathIsolation() throws {
        let baseline = try loadFixture()
        let mutated = baseline.applying(CLIOverrides(telemetryCorpusPath: "/tmp/override-corpus"))
        #expect(mutated.consistency.corpusPath == "/tmp/override-corpus")
        #expect(differingSections(baseline, mutated) == ["consistency"])
        // The shipped bug: complexity/legibility/docCoverage (and newer
        // sections) reverted to defaults under this override.
        #expect(mutated.complexity == baseline.complexity)
        #expect(mutated.legibility == baseline.legibility)
        #expect(mutated.docCoverage == baseline.docCoverage)
        #expect(mutated.consistency.projectID == baseline.consistency.projectID)
    }

    @Test("no overrides is the identity")
    func identity() throws {
        let baseline = try loadFixture()
        let mutated = baseline.applying(CLIOverrides())
        #expect(differingSections(baseline, mutated).isEmpty)
    }
}
