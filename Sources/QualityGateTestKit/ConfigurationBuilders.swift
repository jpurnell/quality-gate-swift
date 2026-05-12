import Foundation
import QualityGateCore

/// Convenience builders for test configurations.
///
/// Provides factory methods for creating ``Configuration`` values
/// commonly needed in checker tests, avoiding repetitive initializer calls.
///
/// ## Example
///
/// ```swift
/// let config = TestConfiguration.withCheckers(["safety"])
/// let result = try await auditor.check(configuration: config)
/// ```
public enum TestConfiguration {

    /// Default configuration for testing.
    public static var `default`: Configuration { Configuration() }

    /// Build a configuration with specific checkers enabled.
    ///
    /// - Parameter checkers: Array of checker identifiers to enable.
    /// - Returns: A configuration that only runs the specified checkers.
    public static func withCheckers(_ checkers: [String]) -> Configuration {
        Configuration(enabledCheckers: checkers)
    }

    /// Build a configuration with specific exclude patterns.
    ///
    /// - Parameter patterns: Glob patterns for files to exclude.
    /// - Returns: A configuration with the given exclude patterns.
    public static func withExcludes(_ patterns: [String]) -> Configuration {
        Configuration(excludePatterns: patterns)
    }
}
