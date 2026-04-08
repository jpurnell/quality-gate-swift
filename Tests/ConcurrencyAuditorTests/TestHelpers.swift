import Foundation
@testable import ConcurrencyAuditor
@testable import QualityGateCore

/// Shared helpers for ConcurrencyAuditor test files.
enum TestHelpers {
    /// Audit a single source string with a fresh auditor.
    static func audit(
        _ code: String,
        firstPartyModules: Set<String> = [],
        allowPreconcurrencyImports: Set<String> = [],
        justificationKeyword: String = "Justification:"
    ) async throws -> CheckResult {
        let auditor = ConcurrencyAuditor(
            firstPartyModules: firstPartyModules,
            allowPreconcurrencyImports: allowPreconcurrencyImports,
            justificationKeyword: justificationKeyword
        )
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: Configuration())
    }
}
