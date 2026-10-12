import Foundation
import Testing
@testable import ContextAuditor
@testable import QualityGateCore

/// An annotation comment that answers a context rule in place of a guard is recorded.
@Suite("context: annotations are recorded")
struct ContextSuppressionRecordingTests {

    private func audit(_ code: String) async throws -> CheckResult {
        try await ContextAuditor().auditSource(
            code, fileName: "Sources/MyApp/Feature.swift", configuration: Configuration())
    }

    @Test("`// CONSENT:` standing in for a permission check is recorded with its reason")
    func consentAnnotation() async throws {
        let code = """
        import CoreLocation
        func start() {
            // CONSENT: onboarding
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "context.missing-consent-guard" }.isEmpty)

        let records = result.overrides.map(SuppressionRecord.init)
            .filter { $0.ruleId == "context.missing-consent-guard" }
        #expect(records.count == 1)
        #expect(records.first?.form == "// CONSENT:")
        #expect(records.first?.kind == .suppressed)
        #expect(records.first?.reason == "onboarding")
        #expect(records.first?.rejection == "1 word, 8 required")
    }

    @Test("Without the annotation the rule fires and nothing is recorded")
    func noAnnotation() async throws {
        let code = """
        import CoreLocation
        func start() {
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "context.missing-consent-guard" }.count == 1)
        #expect(result.overrides.isEmpty)
    }

    @Test("An annotation beside a real permission check silenced nothing and is not recorded")
    func annotationBesideRealGuard() async throws {
        let code = """
        import CoreLocation
        func start(isAuthorized: Bool) {
            // CONSENT: belt and braces
            guard isAuthorized else { return }
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "context.missing-consent-guard" }.isEmpty)
        #expect(result.overrides.isEmpty)
    }
}
