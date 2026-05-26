import Foundation
import Testing
@testable import UnreachableCodeAuditor
@testable import QualityGateCore

/// SwiftUI-awareness tests for the cross-module unreachable code auditor.
///
/// Validates that SwiftUI property wrappers, View members, and Scene
/// members are treated as roots (not flagged as unreachable).
@Suite("UnreachableCodeAuditor SwiftUI awareness", .serialized)
struct SwiftUIAwarenessTests {

    private static let fixtureRoot: URL = {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CrossModuleFixture", isDirectory: true)
    }()

    private static let ruleId = "unreachable.cross_module.unreachable_from_entry"

    private func auditFixture() async throws -> CheckResult {
        let auditor = UnreachableCodeAuditor()
        return try await auditor.auditPackage(at: Self.fixtureRoot, configuration: Configuration())
    }

    private func flagged(_ result: CheckResult, name: String, file: String? = nil) -> Bool {
        result.diagnostics.contains { d in
            d.ruleId == Self.ruleId
            && (d.message.contains(name) == true)
            && (file == nil || d.filePath?.contains(file!) == true)
        }
    }

    // MARK: - @State property (must NOT be flagged)

    @Test("Does not flag @State property in a View")
    func keepsStateProperty() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "count", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - @Binding property (must NOT be flagged)

    @Test("Does not flag @Binding property in a View")
    func keepsBindingProperty() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "isPresented", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - @Environment property (must NOT be flagged)

    @Test("Does not flag @Environment property in a View")
    func keepsEnvironmentProperty() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "dismiss", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - @EnvironmentObject property (must NOT be flagged)

    @Test("Does not flag @EnvironmentObject property in a View")
    func keepsEnvironmentObjectProperty() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "viewModel", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - @Published property (must NOT be flagged)

    @Test("Does not flag @Published property in ObservableObject")
    func keepsPublishedProperty() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "title", file: "SwiftUIPatterns.swift"))
        #expect(!flagged(result, name: "subtitle", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - Stored property in View struct (must NOT be flagged)

    @Test("Does not flag stored let property in a View")
    func keepsViewStoredProperty() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "formatter", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - Helper method in View struct (must NOT be flagged)

    @Test("Does not flag helper method in a View")
    func keepsViewHelperMethod() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "helperMethod", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - @State in View detected by body property

    @Test("Does not flag @State in View detected by body property")
    func keepsInferredViewState() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "active", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - @State in Scene conformance

    @Test("Does not flag @State in Scene struct")
    func keepsSceneState() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "windowTitle", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - @AppStorage property (must NOT be flagged)

    @Test("Does not flag @AppStorage property in a View")
    func keepsAppStorageProperty() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "theme", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - @SceneStorage property (must NOT be flagged)

    @Test("Does not flag @SceneStorage property in a View")
    func keepsSceneStorageProperty() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "selectedTab", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - @FocusState property (must NOT be flagged)

    @Test("Does not flag @FocusState property in a View")
    func keepsFocusStateProperty() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "isFocused", file: "SwiftUIPatterns.swift"))
    }

    // MARK: - Dead code near SwiftUI (must still be flagged)

    @Test("Still flags dead function near SwiftUI code")
    func stillFlagsDeadNearSwiftUI() async throws {
        let result = try await auditFixture()
        #expect(flagged(result, name: "deadNearSwiftUI", file: "SwiftUIPatterns.swift"))
    }
}
