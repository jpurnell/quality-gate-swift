import Foundation
@testable import PointerEscapeAuditor
@testable import QualityGateCore

enum TestHelpers {
    static func audit(
        _ code: String,
        allowedEscapeFunctions: Set<String> = []
    ) async throws -> CheckResult {
        let auditor = PointerEscapeAuditor(allowedEscapeFunctions: allowedEscapeFunctions)
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: Configuration())
    }
}
