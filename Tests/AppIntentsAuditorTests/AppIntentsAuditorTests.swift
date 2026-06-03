import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

@Suite("AppIntentsAuditor integration")
struct AppIntentsAuditorIntegrationTests {

    @Test("Checker ID and name are correct")
    func checkerIdentity() {
        let auditor = AppIntentsAuditor()
        #expect(auditor.id == "appintents-readiness")
        #expect(auditor.name == "App Intents Readiness Auditor")
    }

    @Test("Returns skipped when not enabled")
    func skippedWhenDisabled() async throws {
        let auditor = AppIntentsAuditor()
        let config = Configuration()
        let result = try await auditor.check(configuration: config)
        #expect(result.status == .skipped)
    }
}
