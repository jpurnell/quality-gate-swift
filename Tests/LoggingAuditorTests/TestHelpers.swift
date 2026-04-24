import Foundation
@testable import LoggingAuditor
@testable import QualityGateCore

/// Shared helpers for LoggingAuditor test files.
enum TestHelpers {
    /// Audit a single source string with a fresh auditor.
    static func audit(
        _ code: String,
        projectType: String = "application",
        silentTryKeyword: String = "silent:",
        allowedSilentTryFunctions: [String] = ["Task.sleep", "JSONEncoder", "JSONDecoder"],
        customLoggerNames: [String] = []
    ) async throws -> CheckResult {
        let config = LoggingAuditorConfig(
            projectType: projectType,
            silentTryKeyword: silentTryKeyword,
            allowedSilentTryFunctions: allowedSilentTryFunctions,
            customLoggerNames: customLoggerNames
        )
        let auditor = LoggingAuditor(config: config)
        return try await auditor.auditSource(
            code,
            fileName: "test.swift",
            configuration: Configuration()
        )
    }
}
