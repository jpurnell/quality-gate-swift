import Foundation

/// Command-line overrides that modify a loaded ``Configuration`` for one run.
///
/// Extracted from `QualityGateCLI.run()` (Phase 0, workstream 0.2) so the
/// override behavior is testable: `ConfigurationOverrideIsolationTests` proves
/// that applying any single override leaves every other configuration section
/// untouched.
public struct CLIOverrides: Sendable, Equatable {
    /// `--auto-build-xcode`: force the unreachable checker's Xcode auto-build on.
    public var autoBuildXcode: Bool
    /// `--threshold`: override the cognitive complexity threshold.
    public var threshold: Int?
    /// `--telemetry-corpus-path`: redirect telemetry to a different corpus.
    public var telemetryCorpusPath: String?

    /// Creates a CLI override set.
    public init(autoBuildXcode: Bool = false, threshold: Int? = nil, telemetryCorpusPath: String? = nil) {
        self.autoBuildXcode = autoBuildXcode
        self.threshold = threshold
        self.telemetryCorpusPath = telemetryCorpusPath
    }
}

extension Configuration {
    /// Returns a configuration with the given CLI overrides applied.
    ///
    /// Each override mutates exactly its own field; every other section is
    /// preserved byte-for-byte (guaranteed by the override-isolation tests).
    /// The previous implementation reconstructed `Configuration` memberwise and
    /// silently reverted every unlisted section to its default — nine sections
    /// by the time the bug was caught (L2).
    public func applying(_ overrides: CLIOverrides) -> Configuration {
        var configuration = self
        if overrides.autoBuildXcode {
            configuration.unreachableAutoBuildXcode = true
        }
        if let thresholdOverride = overrides.threshold {
            configuration.complexity.cognitiveThreshold = thresholdOverride
        }
        if let corpusPathOverride = overrides.telemetryCorpusPath {
            configuration.consistency.corpusPath = corpusPathOverride
        }
        return configuration
    }
}
