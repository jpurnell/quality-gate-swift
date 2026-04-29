import Foundation
import Testing
import QualityGateTypes
@testable import ContextAuditor
@testable import QualityGateCore

@Suite("ContextAuditor Tests")
struct ContextAuditorTests {

    // MARK: - Identity Tests

    @Test("ContextAuditor has correct id and name")
    func checkerIdentity() {
        let auditor = ContextAuditor()
        #expect(auditor.id == "context")
        #expect(auditor.name == "Context Auditor")
    }

    // MARK: - Rule: context.missing-consent-guard

    @Test("Detects CLLocationManager usage without consent guard")
    func detectsLocationWithoutConsent() async throws {
        let code = """
        import CoreLocation
        func trackUser() {
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.missing-consent-guard" })
    }

    @Test("Detects CNContactStore usage without consent guard")
    func detectsContactsWithoutConsent() async throws {
        let code = """
        import Contacts
        func fetchContacts() {
            let store = CNContactStore()
            let contacts = try store.enumerateContacts(with: request)
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.missing-consent-guard" })
    }

    @Test("No finding when consent guard present in enclosing scope")
    func noFindingWithConsentGuard() async throws {
        let code = """
        import CoreLocation
        func trackUser() {
            guard ConsentManager.hasLocationConsent() else { return }
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await auditCode(code)
        let consentFindings = result.diagnostics.filter { $0.ruleId == "context.missing-consent-guard" }
        #expect(consentFindings.isEmpty)
    }

    @Test("No finding when CONSENT annotation present")
    func noFindingWithConsentAnnotation() async throws {
        let code = """
        import CoreLocation
        func trackUser() {
            // CONSENT: User explicitly opted in via Settings > Privacy
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await auditCode(code)
        let consentFindings = result.diagnostics.filter { $0.ruleId == "context.missing-consent-guard" }
        #expect(consentFindings.isEmpty)
    }

    @Test("Detects AVCaptureSession without consent guard")
    func detectsCameraWithoutConsent() async throws {
        let code = """
        import AVFoundation
        func startCamera() {
            let session = AVCaptureSession()
            session.startRunning()
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.missing-consent-guard" })
    }

    @Test("Detects HKHealthStore without consent guard")
    func detectsHealthKitWithoutConsent() async throws {
        let code = """
        import HealthKit
        func readHealth() {
            let store = HKHealthStore()
            store.requestAuthorization(toShare: nil, read: types)
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.missing-consent-guard" })
    }

    @Test("Detects EKEventStore without consent guard")
    func detectsCalendarWithoutConsent() async throws {
        let code = """
        import EventKit
        func readCalendar() {
            let store = EKEventStore()
            store.requestAccess(to: .event)
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.missing-consent-guard" })
    }

    @Test("Detects PHPhotoLibrary without consent guard")
    func detectsPhotosWithoutConsent() async throws {
        let code = """
        import Photos
        func accessPhotos() {
            PHPhotoLibrary.requestAuthorization { status in
                // access photos
            }
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.missing-consent-guard" })
    }

    // MARK: - Rule: context.unguarded-analytics

    @Test("Detects analytics tracking without opt-out check")
    func detectsAnalyticsWithoutOptOut() async throws {
        let code = """
        func logEvent() {
            Analytics.track("user_action", properties: [:])
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.unguarded-analytics" })
    }

    @Test("No finding when analytics has opt-out guard")
    func noFindingWithAnalyticsGuard() async throws {
        let code = """
        func logEvent() {
            guard isTrackingAllowed else { return }
            Analytics.track("user_action", properties: [:])
        }
        """
        let result = try await auditCode(code)
        let analyticsFindings = result.diagnostics.filter { $0.ruleId == "context.unguarded-analytics" }
        #expect(analyticsFindings.isEmpty)
    }

    @Test("No finding with ANALYTICS annotation")
    func noFindingWithAnalyticsAnnotation() async throws {
        let code = """
        func logEvent() {
            // ANALYTICS: First-party only, no PII, GDPR compliant
            Analytics.track("user_action", properties: [:])
        }
        """
        let result = try await auditCode(code)
        let analyticsFindings = result.diagnostics.filter { $0.ruleId == "context.unguarded-analytics" }
        #expect(analyticsFindings.isEmpty)
    }

    // MARK: - Rule: context.automated-decision-without-review

    @Test("Detects automated user-affecting decision without review")
    func detectsAutomatedDecisionWithoutReview() async throws {
        let code = """
        func processApplication() {
            let score = model.predict(application)
            if score < threshold {
                denyApplication(application)
            }
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.automated-decision-without-review" })
    }

    @Test("No finding when human review step present")
    func noFindingWithHumanReview() async throws {
        let code = """
        func processApplication() {
            let score = model.predict(application)
            if score < threshold {
                // REVIEWED: Denial requires manager approval via ReviewQueue
                denyApplication(application)
            }
        }
        """
        let result = try await auditCode(code)
        let decisionFindings = result.diagnostics.filter { $0.ruleId == "context.automated-decision-without-review" }
        #expect(decisionFindings.isEmpty)
    }

    // MARK: - Rule: context.surveillance-pattern

    @Test("Detects background location tracking without disclosure")
    func detectsBackgroundLocationWithoutDisclosure() async throws {
        let code = """
        import CoreLocation
        func setupLocation() {
            let manager = CLLocationManager()
            manager.allowsBackgroundLocationUpdates = true
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.surveillance-pattern" })
    }

    @Test("No finding with DISCLOSURE annotation")
    func noFindingWithDisclosureAnnotation() async throws {
        let code = """
        import CoreLocation
        func setupLocation() {
            let manager = CLLocationManager()
            // DISCLOSURE: Background location used for turn-by-turn navigation per privacy policy section 4.2
            manager.allowsBackgroundLocationUpdates = true
        }
        """
        let result = try await auditCode(code)
        let surveillanceFindings = result.diagnostics.filter { $0.ruleId == "context.surveillance-pattern" }
        #expect(surveillanceFindings.isEmpty)
    }

    // MARK: - Test File Exclusion

    @Test("No findings for test files")
    func noFindingsInTestFile() async throws {
        let code = """
        import CoreLocation
        func testLocationTracking() {
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await auditCode(code, fileName: "Tests/MyAppTests/LocationTests.swift")
        #expect(result.diagnostics.isEmpty)
    }

    @Test("No findings for XCTest files")
    func noFindingsInXCTestFile() async throws {
        let code = """
        import CoreLocation
        func testLocationTracking() {
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await auditCode(code, fileName: "XCTests/LocationTests.swift")
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - Scope Tests

    @Test("Consent guard in enclosing function suppresses finding in inner closure")
    func consentGuardSuppressesInnerClosure() async throws {
        let code = """
        import CoreLocation
        func trackUser() {
            guard hasLocationPermission() else { return }
            DispatchQueue.main.async {
                let manager = CLLocationManager()
                manager.startUpdatingLocation()
            }
        }
        """
        let result = try await auditCode(code)
        let consentFindings = result.diagnostics.filter { $0.ruleId == "context.missing-consent-guard" }
        #expect(consentFindings.isEmpty)
    }

    @Test("Consent guard in unrelated function does NOT suppress finding")
    func consentGuardInUnrelatedFunction() async throws {
        let code = """
        import CoreLocation
        func checkPermission() {
            guard hasLocationPermission() else { return }
        }
        func trackUser() {
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "context.missing-consent-guard" })
    }

    // MARK: - Edge Cases

    @Test("Empty source produces no diagnostics")
    func emptySource() async throws {
        let result = try await auditCode("")
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Source with only comments produces no diagnostics")
    func commentsOnly() async throws {
        let code = """
        // This is a comment
        /// This is a doc comment
        /* Block comment */
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Multiple violations in same function produce multiple diagnostics")
    func multipleViolations() async throws {
        let code = """
        import CoreLocation
        import Contacts
        func collectEverything() {
            let locationManager = CLLocationManager()
            locationManager.startUpdatingLocation()
            let contactStore = CNContactStore()
            contactStore.enumerateContacts(with: request)
        }
        """
        let result = try await auditCode(code)
        let consentFindings = result.diagnostics.filter { $0.ruleId == "context.missing-consent-guard" }
        #expect(consentFindings.count >= 2)
    }

    @Test("Diagnostics include file path and line number")
    func diagnosticsIncludeLocation() async throws {
        let code = """
        import CoreLocation
        func trackUser() {
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await auditCode(code)
        let findings = result.diagnostics.filter { $0.ruleId == "context.missing-consent-guard" }
        #expect(findings.allSatisfy { $0.filePath != nil })
        #expect(findings.allSatisfy { $0.lineNumber != nil })
    }

    @Test("Diagnostics include suggested fix")
    func diagnosticsIncludeSuggestedFix() async throws {
        let code = """
        import CoreLocation
        func trackUser() {
            let manager = CLLocationManager()
            manager.startUpdatingLocation()
        }
        """
        let result = try await auditCode(code)
        let findings = result.diagnostics.filter { $0.ruleId == "context.missing-consent-guard" }
        #expect(findings.allSatisfy { $0.suggestedFix != nil })
    }

    // MARK: - Helpers

    private func auditCode(
        _ code: String,
        fileName: String = "Sources/MyApp/Feature.swift"
    ) async throws -> CheckResult {
        let auditor = ContextAuditor()
        let config = Configuration()
        return try await auditor.auditSource(code, fileName: fileName, configuration: config)
    }
}
