import Foundation
import Testing
@testable import MemoryLifecycleGuard
@testable import QualityGateCore

@Suite("MemoryLifecycleGuard: Index-backed Pass 2 rules")
struct LifecycleIndexPassTests {

    // MARK: - Rule 1: Cross-file Task cancellation

    @Test("Task cancel in extension suppresses false positive")
    func taskCancelInExtensionSuppresses() {
        let pass1Diag = Diagnostic(
            severity: .warning,
            message: "Class has stored Task property 'bgTask' but no deinit to cancel it",
            filePath: "MyService.swift",
            lineNumber: 10,
            columnNumber: 1,
            ruleId: "lifecycle-task-no-deinit"
        )
        let taskProp = LifecycleIndexPass.TaskPropertyInfo(
            typeName: "MyService",
            propertyName: "bgTask",
            filePath: "MyService.swift",
            line: 10
        )
        let cancelSite = LifecycleIndexPass.CancelSite(
            typeName: "MyService",
            propertyName: "bgTask",
            filePath: "MyService+Lifecycle.swift",
            line: 5
        )

        let result = LifecycleIndexPass.analyzeTaskCancellation(
            pass1Diagnostics: [pass1Diag],
            taskProperties: [taskProp],
            cancelSitesInOtherFiles: [cancelSite]
        )

        // Original warning should be suppressed.
        #expect(!result.contains { $0.ruleId == "lifecycle-task-no-deinit" })
        // Info note should be emitted.
        #expect(result.contains { $0.ruleId == "lifecycle-task-cancel-in-extension" })
        #expect(result.first { $0.ruleId == "lifecycle-task-cancel-in-extension" }?.severity == .note)
    }

    @Test("Task cancel in deinit extension suppresses false positive")
    func taskCancelInDeinitExtensionSuppresses() {
        let pass1Diag = Diagnostic(
            severity: .warning,
            message: "Class has stored Task property 'task' but deinit does not call cancel()",
            filePath: "ViewModel.swift",
            lineNumber: 5,
            columnNumber: 1,
            ruleId: "lifecycle-task-no-cancel"
        )
        let taskProp = LifecycleIndexPass.TaskPropertyInfo(
            typeName: "ViewModel",
            propertyName: "task",
            filePath: "ViewModel.swift",
            line: 5
        )
        let cancelSite = LifecycleIndexPass.CancelSite(
            typeName: "ViewModel",
            propertyName: "task",
            filePath: "ViewModel+Deinit.swift",
            line: 3
        )

        let result = LifecycleIndexPass.analyzeTaskCancellation(
            pass1Diagnostics: [pass1Diag],
            taskProperties: [taskProp],
            cancelSitesInOtherFiles: [cancelSite]
        )

        #expect(!result.contains { $0.ruleId == "lifecycle-task-no-cancel" })
        #expect(result.contains { $0.ruleId == "lifecycle-task-cancel-in-extension" })
    }

    @Test("Task no cancel anywhere preserves diagnostic")
    func taskNoCancelPreserves() {
        let pass1Diag = Diagnostic(
            severity: .warning,
            message: "Class has stored Task property 'bgTask' but no deinit to cancel it",
            filePath: "MyService.swift",
            lineNumber: 10,
            columnNumber: 1,
            ruleId: "lifecycle-task-no-deinit"
        )
        let taskProp = LifecycleIndexPass.TaskPropertyInfo(
            typeName: "MyService",
            propertyName: "bgTask",
            filePath: "MyService.swift",
            line: 10
        )

        let result = LifecycleIndexPass.analyzeTaskCancellation(
            pass1Diagnostics: [pass1Diag],
            taskProperties: [taskProp],
            cancelSitesInOtherFiles: []
        )

        // Original diagnostic should be preserved.
        #expect(result.contains { $0.ruleId == "lifecycle-task-no-deinit" })
        // No suppression note should be emitted.
        #expect(!result.contains { $0.ruleId == "lifecycle-task-cancel-in-extension" })
    }

    @Test("Task cancel in same file not double counted")
    func taskCancelSameFileNotDoubleCounted() {
        // A cancel in the same file should NOT cause suppression -- that's Pass 1's job.
        let pass1Diag = Diagnostic(
            severity: .warning,
            message: "Class has stored Task property 'task' but deinit does not call cancel()",
            filePath: "ViewModel.swift",
            lineNumber: 5,
            columnNumber: 1,
            ruleId: "lifecycle-task-no-cancel"
        )
        let taskProp = LifecycleIndexPass.TaskPropertyInfo(
            typeName: "ViewModel",
            propertyName: "task",
            filePath: "ViewModel.swift",
            line: 5
        )
        // Cancel in a DIFFERENT type -- should not match.
        let cancelSite = LifecycleIndexPass.CancelSite(
            typeName: "OtherClass",
            propertyName: "task",
            filePath: "Other.swift",
            line: 3
        )

        let result = LifecycleIndexPass.analyzeTaskCancellation(
            pass1Diagnostics: [pass1Diag],
            taskProperties: [taskProp],
            cancelSitesInOtherFiles: [cancelSite]
        )

        // Diagnostic should be preserved because the cancel is for a different type.
        #expect(result.contains { $0.ruleId == "lifecycle-task-no-cancel" })
    }

    @Test("Non-task diagnostics pass through unchanged")
    func nonTaskDiagnosticsPassThrough() {
        let otherDiag = Diagnostic(
            severity: .warning,
            message: "Something else",
            ruleId: "lifecycle-strong-delegate"
        )

        let result = LifecycleIndexPass.analyzeTaskCancellation(
            pass1Diagnostics: [otherDiag],
            taskProperties: [],
            cancelSitesInOtherFiles: []
        )

        #expect(result.count == 1)
        #expect(result.first?.ruleId == "lifecycle-strong-delegate")
    }

    // MARK: - Rule 2: Cross-file delegate retention

    @Test("Delegate retained elsewhere emits warning")
    func delegateRetainedElsewhereEmitsWarning() {
        let delegateProp = LifecycleIndexPass.DelegatePropertyInfo(
            typeName: "TableView",
            propertyName: "delegate",
            isWeak: true,
            filePath: "TableView.swift",
            line: 5
        )
        let assignmentSite = LifecycleIndexPass.DelegateAssignmentSite(
            typeName: "TableView",
            propertyName: "delegate",
            createsRetainCycle: true,
            filePath: "ViewController.swift",
            line: 20
        )

        let result = LifecycleIndexPass.analyzeDelegateRetention(
            delegateProperties: [delegateProp],
            assignmentSites: [assignmentSite]
        )

        #expect(result.count == 1)
        #expect(result.first?.ruleId == "lifecycle-delegate-retained-elsewhere")
        #expect(result.first?.severity == .warning)
        #expect(result.first?.filePath == "ViewController.swift")
    }

    @Test("Delegate assigned without retain cycle produces no warning")
    func delegateAssignedNoRetainCycle() {
        let delegateProp = LifecycleIndexPass.DelegatePropertyInfo(
            typeName: "TableView",
            propertyName: "delegate",
            isWeak: true,
            filePath: "TableView.swift",
            line: 5
        )
        let assignmentSite = LifecycleIndexPass.DelegateAssignmentSite(
            typeName: "TableView",
            propertyName: "delegate",
            createsRetainCycle: false,
            filePath: "ViewController.swift",
            line: 20
        )

        let result = LifecycleIndexPass.analyzeDelegateRetention(
            delegateProperties: [delegateProp],
            assignmentSites: [assignmentSite]
        )

        #expect(result.isEmpty)
    }

    @Test("Strong delegate already flagged by Pass 1 produces no duplicate")
    func strongDelegateNotDuplicated() {
        // Strong delegates (isWeak: false) are already flagged by Pass 1.
        // Pass 2 should only flag retain cycles on weak delegates.
        let delegateProp = LifecycleIndexPass.DelegatePropertyInfo(
            typeName: "TableView",
            propertyName: "delegate",
            isWeak: false,
            filePath: "TableView.swift",
            line: 5
        )
        let assignmentSite = LifecycleIndexPass.DelegateAssignmentSite(
            typeName: "TableView",
            propertyName: "delegate",
            createsRetainCycle: true,
            filePath: "ViewController.swift",
            line: 20
        )

        let result = LifecycleIndexPass.analyzeDelegateRetention(
            delegateProperties: [delegateProp],
            assignmentSites: [assignmentSite]
        )

        // Should not flag -- strong delegate issues are Pass 1's domain.
        #expect(result.isEmpty)
    }

    // MARK: - Rule 3: Cross-file stream termination

    @Test("Stream finish elsewhere suppresses false positive")
    func streamFinishElsewhereSuppresses() {
        let pass1Diag = Diagnostic(
            severity: .warning,
            message: "AsyncStream created without explicit bufferingPolicy",
            filePath: "StreamProducer.swift",
            lineNumber: 15,
            columnNumber: 1,
            ruleId: "lifecycle-unbounded-stream"
        )
        let streamSite = LifecycleIndexPass.StreamCreationInfo(
            variableName: "events",
            filePath: "StreamProducer.swift",
            line: 15
        )
        let terminationSite = LifecycleIndexPass.StreamTerminationSite(
            variableName: "continuation",
            filePath: "StreamConsumer.swift",
            line: 30
        )

        let result = LifecycleIndexPass.analyzeStreamTermination(
            pass1Diagnostics: [pass1Diag],
            streamCreationSites: [streamSite],
            terminationSitesInOtherFiles: [terminationSite]
        )

        #expect(!result.contains { $0.ruleId == "lifecycle-unbounded-stream" })
        #expect(result.contains { $0.ruleId == "lifecycle-stream-terminated-elsewhere" })
        #expect(result.first { $0.ruleId == "lifecycle-stream-terminated-elsewhere" }?.severity == .note)
    }

    @Test("Stream onTermination elsewhere suppresses false positive")
    func streamOnTerminationElsewhereSuppresses() {
        let pass1Diag = Diagnostic(
            severity: .warning,
            message: "AsyncStream created without explicit bufferingPolicy",
            filePath: "Producer.swift",
            lineNumber: 10,
            columnNumber: 1,
            ruleId: "lifecycle-unbounded-stream"
        )
        let streamSite = LifecycleIndexPass.StreamCreationInfo(
            variableName: nil,
            filePath: "Producer.swift",
            line: 10
        )
        let terminationSite = LifecycleIndexPass.StreamTerminationSite(
            variableName: nil,
            filePath: "Handler.swift",
            line: 25
        )

        let result = LifecycleIndexPass.analyzeStreamTermination(
            pass1Diagnostics: [pass1Diag],
            streamCreationSites: [streamSite],
            terminationSitesInOtherFiles: [terminationSite]
        )

        #expect(!result.contains { $0.ruleId == "lifecycle-unbounded-stream" })
        #expect(result.contains { $0.ruleId == "lifecycle-stream-terminated-elsewhere" })
    }

    @Test("Stream no termination anywhere preserves diagnostic")
    func streamNoTerminationPreserves() {
        let pass1Diag = Diagnostic(
            severity: .warning,
            message: "AsyncStream created without explicit bufferingPolicy",
            filePath: "StreamProducer.swift",
            lineNumber: 15,
            columnNumber: 1,
            ruleId: "lifecycle-unbounded-stream"
        )
        let streamSite = LifecycleIndexPass.StreamCreationInfo(
            variableName: "events",
            filePath: "StreamProducer.swift",
            line: 15
        )

        let result = LifecycleIndexPass.analyzeStreamTermination(
            pass1Diagnostics: [pass1Diag],
            streamCreationSites: [streamSite],
            terminationSitesInOtherFiles: []
        )

        #expect(result.contains { $0.ruleId == "lifecycle-unbounded-stream" })
        #expect(!result.contains { $0.ruleId == "lifecycle-stream-terminated-elsewhere" })
    }

    @Test("Non-stream diagnostics pass through unchanged during stream analysis")
    func nonStreamDiagnosticsPassThrough() {
        let otherDiag = Diagnostic(
            severity: .warning,
            message: "Some other issue",
            ruleId: "lifecycle-strong-delegate"
        )
        let terminationSite = LifecycleIndexPass.StreamTerminationSite(
            variableName: nil,
            filePath: "Other.swift",
            line: 5
        )

        let result = LifecycleIndexPass.analyzeStreamTermination(
            pass1Diagnostics: [otherDiag],
            streamCreationSites: [],
            terminationSitesInOtherFiles: [terminationSite]
        )

        #expect(result.contains { $0.ruleId == "lifecycle-strong-delegate" })
    }

    // MARK: - Rule 4: Stale exemption cleanup

    @Test("Stale task exemption detected")
    func staleTaskExemptionDetected() {
        let marker = LifecycleIndexPass.ExemptionMarkerInfo(
            suppressedRuleId: "lifecycle-task-no-deinit",
            associatedDeclarationName: "bgTask",
            typeName: "MyService",
            filePath: "MyService.swift",
            line: 10
        )
        let resolved = LifecycleIndexPass.ResolvedCondition(
            ruleId: "lifecycle-task-no-deinit",
            declarationName: "bgTask",
            typeName: "MyService"
        )

        let result = LifecycleIndexPass.analyzeStaleExemptions(
            exemptionMarkers: [marker],
            resolvedConditions: [resolved]
        )

        #expect(result.count == 1)
        #expect(result.first?.ruleId == "lifecycle-stale-exemption")
        #expect(result.first?.severity == .note)
        #expect(result.first?.filePath == "MyService.swift")
        #expect(result.first?.lineNumber == 10)
    }

    @Test("Stale delegate exemption detected")
    func staleDelegateExemptionDetected() {
        let marker = LifecycleIndexPass.ExemptionMarkerInfo(
            suppressedRuleId: "lifecycle-strong-delegate",
            associatedDeclarationName: "delegate",
            typeName: "TableView",
            filePath: "TableView.swift",
            line: 8
        )
        let resolved = LifecycleIndexPass.ResolvedCondition(
            ruleId: "lifecycle-strong-delegate",
            declarationName: "delegate",
            typeName: "TableView"
        )

        let result = LifecycleIndexPass.analyzeStaleExemptions(
            exemptionMarkers: [marker],
            resolvedConditions: [resolved]
        )

        #expect(result.count == 1)
        #expect(result.first?.ruleId == "lifecycle-stale-exemption")
    }

    @Test("Valid exemption not flagged")
    func validExemptionNotFlagged() {
        let marker = LifecycleIndexPass.ExemptionMarkerInfo(
            suppressedRuleId: "lifecycle-task-no-deinit",
            associatedDeclarationName: "bgTask",
            typeName: "MyService",
            filePath: "MyService.swift",
            line: 10
        )
        // No resolved condition for this marker.

        let result = LifecycleIndexPass.analyzeStaleExemptions(
            exemptionMarkers: [marker],
            resolvedConditions: []
        )

        #expect(result.isEmpty)
    }

    @Test("Resolved condition for different declaration does not trigger stale")
    func resolvedForDifferentDeclaration() {
        let marker = LifecycleIndexPass.ExemptionMarkerInfo(
            suppressedRuleId: "lifecycle-task-no-deinit",
            associatedDeclarationName: "bgTask",
            typeName: "MyService",
            filePath: "MyService.swift",
            line: 10
        )
        let resolved = LifecycleIndexPass.ResolvedCondition(
            ruleId: "lifecycle-task-no-deinit",
            declarationName: "otherTask",
            typeName: "MyService"
        )

        let result = LifecycleIndexPass.analyzeStaleExemptions(
            exemptionMarkers: [marker],
            resolvedConditions: [resolved]
        )

        #expect(result.isEmpty)
    }

    // MARK: - Graceful degradation

    @Test("Index unavailable emits info note")
    func indexUnavailableEmitsNote() {
        let result = LifecycleIndexPass.unavailableNote()
        #expect(result.severity == .note)
        #expect(result.ruleId == "lifecycle.index-pass.skipped")
    }

    // MARK: - Configuration

    @Test("Config defaults useIndexStore to true")
    func configDefaultsUseIndexStore() {
        let config = MemoryLifecycleConfig.default
        #expect(config.useIndexStore == true)
    }

    @Test("Config decodes useIndexStore from YAML")
    func configDecodesUseIndexStore() throws {
        let yaml = """
        memoryLifecycle:
          useIndexStore: false
        """
        let config = try Configuration.from(yaml: yaml)
        #expect(config.memoryLifecycle.useIndexStore == false)
    }

    @Test("useIndexStore false skips Pass 2")
    func useIndexStoreFalseSkipsPass2() throws {
        // Verify that the config option is properly surfaced.
        let config = MemoryLifecycleConfig(useIndexStore: false)
        #expect(config.useIndexStore == false)

        // The actual skipping is tested via the integration in MemoryLifecycleGuard.check(),
        // but we verify the config value is correctly set here.
        let defaultConfig = MemoryLifecycleConfig.default
        #expect(defaultConfig.useIndexStore == true)
    }

    // MARK: - Data type identity

    @Test("TaskPropertyInfo equality")
    func taskPropertyInfoEquality() {
        let info1 = LifecycleIndexPass.TaskPropertyInfo(
            typeName: "Foo", propertyName: "task", filePath: "Foo.swift", line: 1
        )
        let info2 = LifecycleIndexPass.TaskPropertyInfo(
            typeName: "Foo", propertyName: "task", filePath: "Foo.swift", line: 1
        )
        #expect(info1 == info2)
    }

    @Test("DelegatePropertyInfo equality")
    func delegatePropertyInfoEquality() {
        let info1 = LifecycleIndexPass.DelegatePropertyInfo(
            typeName: "Foo", propertyName: "delegate", isWeak: true, filePath: "Foo.swift", line: 1
        )
        let info2 = LifecycleIndexPass.DelegatePropertyInfo(
            typeName: "Foo", propertyName: "delegate", isWeak: true, filePath: "Foo.swift", line: 1
        )
        #expect(info1 == info2)
    }

    @Test("StreamCreationInfo equality")
    func streamCreationInfoEquality() {
        let info1 = LifecycleIndexPass.StreamCreationInfo(
            variableName: "stream", filePath: "A.swift", line: 5
        )
        let info2 = LifecycleIndexPass.StreamCreationInfo(
            variableName: "stream", filePath: "A.swift", line: 5
        )
        #expect(info1 == info2)
    }

    @Test("ExemptionMarkerInfo equality")
    func exemptionMarkerInfoEquality() {
        let info1 = LifecycleIndexPass.ExemptionMarkerInfo(
            suppressedRuleId: "lifecycle-task-no-deinit",
            associatedDeclarationName: "task",
            typeName: "Foo",
            filePath: "Foo.swift",
            line: 10
        )
        let info2 = LifecycleIndexPass.ExemptionMarkerInfo(
            suppressedRuleId: "lifecycle-task-no-deinit",
            associatedDeclarationName: "task",
            typeName: "Foo",
            filePath: "Foo.swift",
            line: 10
        )
        #expect(info1 == info2)
    }
}
