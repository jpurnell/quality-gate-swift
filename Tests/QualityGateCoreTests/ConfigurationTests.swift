import Foundation
import Testing
@testable import QualityGateCore

/// Tests for the Configuration model.
///
/// Configuration represents project-specific settings loaded from .quality-gate.yml
@Suite("Configuration Model Tests")
struct ConfigurationTests {

    // MARK: - Default Configuration Tests

    @Test("Default configuration has sensible defaults")
    func defaultConfiguration() {
        let config = Configuration()

        #expect(config.parallelWorkers == nil) // Uses system default
        #expect(config.excludePatterns.isEmpty)
        #expect(config.safetyExemptions == ["// SAFETY:"])
        #expect(config.enabledCheckers.isEmpty) // Empty means all enabled
    }

    // MARK: - Initialization Tests

    @Test("Configuration initializes with custom values")
    func customConfiguration() {
        let config = Configuration(
            parallelWorkers: 4,
            excludePatterns: ["**/Generated/**", "**/Vendor/**"],
            safetyExemptions: ["// SAFETY:", "// swiftlint:disable"],
            enabledCheckers: ["build", "test", "safety"]
        )

        #expect(config.parallelWorkers == 4)
        #expect(config.excludePatterns.count == 2)
        #expect(config.safetyExemptions.count == 2)
        #expect(config.enabledCheckers.count == 3)
    }

    // MARK: - YAML Parsing Tests

    @Test("Configuration parses from valid YAML")
    func parsesFromYAML() throws {
        let yaml = """
        parallelWorkers: 8
        excludePatterns:
          - "**/Generated/**"
          - "**/Build/**"
        safetyExemptions:
          - "// SAFETY:"
          - "// @unsafe"
        enabledCheckers:
          - build
          - test
        """

        let config = try Configuration.from(yaml: yaml)

        #expect(config.parallelWorkers == 8)
        #expect(config.excludePatterns.count == 2)
        #expect(config.excludePatterns.contains("**/Generated/**"))
        #expect(config.safetyExemptions.count == 2)
        #expect(config.enabledCheckers.count == 2)
    }

    @Test("Configuration uses defaults for missing YAML fields")
    func usesDefaultsForMissingFields() throws {
        let yaml = """
        parallelWorkers: 4
        """

        let config = try Configuration.from(yaml: yaml)

        #expect(config.parallelWorkers == 4)
        #expect(config.excludePatterns.isEmpty)
        #expect(config.safetyExemptions == ["// SAFETY:"])
    }

    @Test("Configuration throws for invalid YAML")
    func throwsForInvalidYAML() {
        let invalidYAML = """
        parallelWorkers: "not a number"
        """

        #expect(throws: QualityGateError.self) {
            try Configuration.from(yaml: invalidYAML)
        }
    }

    // MARK: - File Loading Tests

    @Test("Configuration loads from file path")
    func loadsFromFile() async throws {
        // Create a temporary config file
        let tempDir = FileManager.default.temporaryDirectory
        let configPath = tempDir.appendingPathComponent(".quality-gate.yml")

        let yaml = """
        parallelWorkers: 6
        enabledCheckers:
          - safety
        """

        try yaml.write(to: configPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: configPath)
        }

        let config = try Configuration.load(from: configPath.path)

        #expect(config.parallelWorkers == 6)
        #expect(config.enabledCheckers == ["safety"])
    }

    @Test("Configuration returns default when file not found")
    func returnsDefaultWhenFileNotFound() throws {
        let config = try Configuration.load(from: "/nonexistent/.quality-gate.yml")

        // Should return default configuration, not throw
        #expect(config.parallelWorkers == nil)
        #expect(config.excludePatterns.isEmpty)
    }

    // MARK: - Checker Enablement Tests

    @Test("isCheckerEnabled returns true when enabledCheckers is empty")
    func isCheckerEnabledWhenEmpty() {
        let config = Configuration(enabledCheckers: [])

        #expect(config.isCheckerEnabled("build") == true)
        #expect(config.isCheckerEnabled("test") == true)
        #expect(config.isCheckerEnabled("any-checker") == true)
    }

    @Test("isCheckerEnabled returns true only for listed checkers")
    func isCheckerEnabledWhenSpecified() {
        let config = Configuration(enabledCheckers: ["build", "test"])

        #expect(config.isCheckerEnabled("build") == true)
        #expect(config.isCheckerEnabled("test") == true)
        #expect(config.isCheckerEnabled("safety") == false)
        #expect(config.isCheckerEnabled("doc-lint") == false)
    }

    // MARK: - Computed Workers Tests

    @Test("effectiveWorkers returns configured value when set")
    func effectiveWorkersWithConfiguredValue() {
        let config = Configuration(parallelWorkers: 4)

        #expect(config.effectiveWorkers == 4)
    }

    @Test("effectiveWorkers computes from system cores when not set")
    func effectiveWorkersFromSystemCores() {
        let config = Configuration(parallelWorkers: nil)

        let workers = config.effectiveWorkers
        // Should be approximately 80% of cores, minimum 1
        #expect(workers >= 1)
        #expect(workers <= ProcessInfo.processInfo.processorCount)
    }

    // MARK: - Sendable Compliance

    @Test("Configuration is Sendable")
    func isSendable() async {
        let config = Configuration(parallelWorkers: 8)

        let workers = await Task {
            config.parallelWorkers
        }.value

        #expect(workers == 8)
    }
}
