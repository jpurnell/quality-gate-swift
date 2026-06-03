import Foundation
import QualityGateCore

/// Cross-file memory lifecycle analysis backed by IndexStoreDB (Pass 2).
///
/// Addresses four categories of false positives and stale annotations that
/// single-file (Pass 1) analysis cannot resolve:
///
/// 1. **Cross-file Task cancellation** -- A class declares a `Task` property
///    in one file but the `deinit` or `.cancel()` call lives in an extension
///    in another file.  Pass 2 suppresses the false positive and emits
///    `lifecycle-task-cancel-in-extension` info.
///
/// 2. **Cross-file delegate retention** -- A `weak` delegate is assigned
///    `self` in another file where `self` retains the delegate's owner,
///    creating a retain cycle.  Pass 2 emits
///    `lifecycle-delegate-retained-elsewhere` warning.
///
/// 3. **Cross-file stream termination** -- `AsyncStream.makeStream()` flagged
///    by Pass 1, but `continuation.finish()` exists in another file.  Pass 2
///    suppresses the false positive and emits
///    `lifecycle-stream-terminated-elsewhere` info.
///
/// 4. **Stale exemption cleanup** -- `// lifecycle:exempt` comments that are
///    no longer needed because the underlying issue was fixed.  Pass 2 emits
///    `lifecycle-stale-exemption` info.
///
/// The analysis logic is split into pure functions so that unit tests can
/// exercise them without a live IndexStoreDB session.  The orchestration
/// entry point lives in ``MemoryLifecycleGuard``.
///
/// ## Graceful degradation
/// When the index store is unavailable the pass emits a single `.note`
/// diagnostic and returns -- it never fails the quality gate.
public enum LifecycleIndexPass: Sendable {

    // MARK: - Data Types

    /// Aggregated inputs from Pass 1 needed by Pass 2 analysis.
    public struct Inputs: Sendable {
        /// Pass 1 diagnostics to potentially suppress.
        public let pass1Diagnostics: [Diagnostic]
        /// Task property declarations found during Pass 1.
        public let taskProperties: [TaskPropertyInfo]
        /// Delegate property declarations found during Pass 1.
        public let delegateProperties: [DelegatePropertyInfo]
        /// AsyncStream creation sites found during Pass 1.
        public let streamCreationSites: [StreamCreationInfo]
        /// `// lifecycle:exempt` markers found during Pass 1.
        public let exemptionMarkers: [ExemptionMarkerInfo]

        /// Creates a Pass 2 inputs bundle.
        ///
        /// - Parameters:
        ///   - pass1Diagnostics: Diagnostics emitted by Pass 1.
        ///   - taskProperties: Task property info collected during Pass 1.
        ///   - delegateProperties: Delegate property info collected during Pass 1.
        ///   - streamCreationSites: Stream creation info collected during Pass 1.
        ///   - exemptionMarkers: Exemption marker info collected during Pass 1.
        public init(
            pass1Diagnostics: [Diagnostic],
            taskProperties: [TaskPropertyInfo],
            delegateProperties: [DelegatePropertyInfo],
            streamCreationSites: [StreamCreationInfo],
            exemptionMarkers: [ExemptionMarkerInfo]
        ) {
            self.pass1Diagnostics = pass1Diagnostics
            self.taskProperties = taskProperties
            self.delegateProperties = delegateProperties
            self.streamCreationSites = streamCreationSites
            self.exemptionMarkers = exemptionMarkers
        }
    }

    /// Describes a stored Task property found during Pass 1.
    public struct TaskPropertyInfo: Sendable, Equatable {
        /// The enclosing type name (class).
        public let typeName: String
        /// The property name (e.g. `"backgroundTask"`).
        public let propertyName: String
        /// File where the property is declared.
        public let filePath: String
        /// 1-based line number of the declaration.
        public let line: Int

        /// Creates a task property info record.
        ///
        /// - Parameters:
        ///   - typeName: The enclosing class name.
        ///   - propertyName: The property identifier.
        ///   - filePath: Absolute file path.
        ///   - line: 1-based line number.
        public init(typeName: String, propertyName: String, filePath: String, line: Int) {
            self.typeName = typeName
            self.propertyName = propertyName
            self.filePath = filePath
            self.line = line
        }
    }

    /// Describes a delegate-pattern property found during Pass 1.
    public struct DelegatePropertyInfo: Sendable, Equatable {
        /// The enclosing type name (class).
        public let typeName: String
        /// The property name (e.g. `"delegate"`).
        public let propertyName: String
        /// Whether the property has a `weak` modifier.
        public let isWeak: Bool
        /// File where the property is declared.
        public let filePath: String
        /// 1-based line number of the declaration.
        public let line: Int

        /// Creates a delegate property info record.
        ///
        /// - Parameters:
        ///   - typeName: The enclosing class name.
        ///   - propertyName: The property identifier.
        ///   - isWeak: Whether the `weak` keyword is present.
        ///   - filePath: Absolute file path.
        ///   - line: 1-based line number.
        public init(typeName: String, propertyName: String, isWeak: Bool, filePath: String, line: Int) {
            self.typeName = typeName
            self.propertyName = propertyName
            self.isWeak = isWeak
            self.filePath = filePath
            self.line = line
        }
    }

    /// Describes an `AsyncStream.makeStream()` or `AsyncStream(...)` creation site.
    public struct StreamCreationInfo: Sendable, Equatable {
        /// The variable name bound to the stream result, if determinable.
        public let variableName: String?
        /// File where the stream is created.
        public let filePath: String
        /// 1-based line number.
        public let line: Int

        /// Creates a stream creation info record.
        ///
        /// - Parameters:
        ///   - variableName: The bound variable name, or nil.
        ///   - filePath: Absolute file path.
        ///   - line: 1-based line number.
        public init(variableName: String?, filePath: String, line: Int) {
            self.variableName = variableName
            self.filePath = filePath
            self.line = line
        }
    }

    /// Describes a `// lifecycle:exempt` marker in source.
    public struct ExemptionMarkerInfo: Sendable, Equatable {
        /// The rule ID that was suppressed (e.g. `"lifecycle-task-no-deinit"`).
        public let suppressedRuleId: String
        /// The declaration name associated with the exemption.
        public let associatedDeclarationName: String
        /// The enclosing type name, if determinable.
        public let typeName: String?
        /// File where the exemption marker appears.
        public let filePath: String
        /// 1-based line number.
        public let line: Int

        /// Creates an exemption marker info record.
        ///
        /// - Parameters:
        ///   - suppressedRuleId: The rule being suppressed.
        ///   - associatedDeclarationName: The associated declaration name.
        ///   - typeName: The enclosing type, or nil.
        ///   - filePath: Absolute file path.
        ///   - line: 1-based line number.
        public init(
            suppressedRuleId: String,
            associatedDeclarationName: String,
            typeName: String?,
            filePath: String,
            line: Int
        ) {
            self.suppressedRuleId = suppressedRuleId
            self.associatedDeclarationName = associatedDeclarationName
            self.typeName = typeName
            self.filePath = filePath
            self.line = line
        }
    }

    /// Describes a cancel call site found via the index in another file.
    public struct CancelSite: Sendable, Equatable {
        /// The type name where the cancel was found.
        public let typeName: String
        /// The property name being cancelled.
        public let propertyName: String
        /// File where the cancel call was found.
        public let filePath: String
        /// 1-based line number.
        public let line: Int

        /// Creates a cancel site record.
        ///
        /// - Parameters:
        ///   - typeName: The enclosing type name.
        ///   - propertyName: The property being cancelled.
        ///   - filePath: Absolute file path.
        ///   - line: 1-based line number.
        public init(typeName: String, propertyName: String, filePath: String, line: Int) {
            self.typeName = typeName
            self.propertyName = propertyName
            self.filePath = filePath
            self.line = line
        }
    }

    /// Describes a delegate assignment site found via the index.
    public struct DelegateAssignmentSite: Sendable, Equatable {
        /// The type name whose delegate is being assigned.
        public let typeName: String
        /// The delegate property name.
        public let propertyName: String
        /// Whether the assignment creates a retain cycle (self retains the delegate's owner).
        public let createsRetainCycle: Bool
        /// File where the assignment occurs.
        public let filePath: String
        /// 1-based line number.
        public let line: Int

        /// Creates a delegate assignment site record.
        ///
        /// - Parameters:
        ///   - typeName: The enclosing type name.
        ///   - propertyName: The delegate property name.
        ///   - createsRetainCycle: Whether the assignment creates a retain cycle.
        ///   - filePath: Absolute file path.
        ///   - line: 1-based line number.
        public init(typeName: String, propertyName: String, createsRetainCycle: Bool, filePath: String, line: Int) {
            self.typeName = typeName
            self.propertyName = propertyName
            self.createsRetainCycle = createsRetainCycle
            self.filePath = filePath
            self.line = line
        }
    }

    /// Describes a stream termination site found via the index in another file.
    public struct StreamTerminationSite: Sendable, Equatable {
        /// The continuation or stream variable name.
        public let variableName: String?
        /// File where the termination occurs.
        public let filePath: String
        /// 1-based line number.
        public let line: Int

        /// Creates a stream termination site record.
        ///
        /// - Parameters:
        ///   - variableName: The continuation variable name, or nil.
        ///   - filePath: Absolute file path.
        ///   - line: 1-based line number.
        public init(variableName: String?, filePath: String, line: Int) {
            self.variableName = variableName
            self.filePath = filePath
            self.line = line
        }
    }

    /// Describes a condition that has been resolved (no longer needs exemption).
    public struct ResolvedCondition: Sendable, Equatable {
        /// The rule ID whose condition is resolved.
        public let ruleId: String
        /// The declaration name that was fixed.
        public let declarationName: String
        /// The enclosing type name, if applicable.
        public let typeName: String?

        /// Creates a resolved condition record.
        ///
        /// - Parameters:
        ///   - ruleId: The rule that no longer applies.
        ///   - declarationName: The declaration that was fixed.
        ///   - typeName: The enclosing type, or nil.
        public init(ruleId: String, declarationName: String, typeName: String?) {
            self.ruleId = ruleId
            self.declarationName = declarationName
            self.typeName = typeName
        }
    }

    // MARK: - Rule 1: Cross-file Task cancellation

    /// Analyzes Task properties for cross-file cancellation.
    ///
    /// When Pass 1 flags a class for having a `Task` property without `deinit`
    /// or without `.cancel()` in `deinit`, this function checks whether a
    /// cancel call exists in an extension in another file.  If found, the
    /// original Pass 1 diagnostic is suppressed and an informational
    /// `lifecycle-task-cancel-in-extension` diagnostic is emitted instead.
    ///
    /// - Parameters:
    ///   - pass1Diagnostics: Diagnostics from Pass 1 to potentially suppress.
    ///   - taskProperties: Task properties collected during Pass 1.
    ///   - cancelSitesInOtherFiles: Cancel call sites found via the index.
    /// - Returns: Diagnostics with false positives suppressed and info notes added.
    public static func analyzeTaskCancellation(
        pass1Diagnostics: [Diagnostic],
        taskProperties: [TaskPropertyInfo],
        cancelSitesInOtherFiles: [CancelSite]
    ) -> [Diagnostic] {
        let taskRuleIds: Set<String> = ["lifecycle-task-no-deinit", "lifecycle-task-no-cancel"]

        // Build a set of (typeName, propertyName) pairs that have cancel in another file.
        let cancelledPairs: Set<String> = Set(cancelSitesInOtherFiles.map { "\($0.typeName).\($0.propertyName)" })

        // Build a set of (typeName, propertyName) pairs from task properties for lookup.
        let taskPropsByFile: [String: [TaskPropertyInfo]] = Dictionary(
            grouping: taskProperties, by: { $0.filePath }
        )

        var result: [Diagnostic] = []
        var suppressedAny = false

        for diag in pass1Diagnostics {
            guard taskRuleIds.contains(diag.ruleId ?? "") else {
                result.append(diag)
                continue
            }

            // Try to match this diagnostic to a task property.
            let matchingProps: [TaskPropertyInfo]
            if let diagFile = diag.filePath, let propsInFile = taskPropsByFile[diagFile] {
                matchingProps = propsInFile.filter { prop in
                    diag.lineNumber == prop.line
                }
            } else {
                matchingProps = []
            }

            let hasCancelElsewhere = matchingProps.contains { prop in
                cancelledPairs.contains("\(prop.typeName).\(prop.propertyName)")
            }

            if hasCancelElsewhere {
                // Suppress the false positive; emit info instead.
                suppressedAny = true
            } else {
                // No cancel found in other files; preserve the original diagnostic.
                result.append(diag)
            }
        }

        if suppressedAny {
            result.append(Diagnostic(
                severity: .note,
                message: "Task cancellation found in extension file; Pass 1 false positive suppressed",
                ruleId: "lifecycle-task-cancel-in-extension"
            ))
        }

        return result
    }

    // MARK: - Rule 2: Cross-file delegate retention

    /// Analyzes delegate properties for cross-file retain cycles.
    ///
    /// When a `weak` delegate property is assigned `self` in another file
    /// where `self` retains the delegate's owner, a retain cycle is created.
    /// This function emits `lifecycle-delegate-retained-elsewhere` warnings
    /// for such cases.
    ///
    /// - Parameters:
    ///   - delegateProperties: Delegate properties collected during Pass 1.
    ///   - assignmentSites: Delegate assignment sites found via the index.
    /// - Returns: Warning diagnostics for detected cross-file retain cycles.
    public static func analyzeDelegateRetention(
        delegateProperties: [DelegatePropertyInfo],
        assignmentSites: [DelegateAssignmentSite]
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        for site in assignmentSites {
            guard site.createsRetainCycle else { continue }

            // Only flag if the delegate property is weak (strong delegates
            // are already flagged by Pass 1 as lifecycle-strong-delegate).
            let matchingProp = delegateProperties.first { prop in
                prop.typeName == site.typeName
                && prop.propertyName == site.propertyName
                && prop.isWeak
            }

            guard let prop = matchingProp else { continue }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "Weak delegate '\(prop.propertyName)' on '\(prop.typeName)' is assigned in \(site.filePath) where self retains the delegate's owner, creating a retain cycle",
                filePath: site.filePath,
                lineNumber: site.line,
                columnNumber: 1,
                ruleId: "lifecycle-delegate-retained-elsewhere",
                suggestedFix: "Break the retain cycle by using a weak reference or restructuring ownership."
            ))
        }

        return diagnostics
    }

    // MARK: - Rule 3: Cross-file stream termination

    /// Analyzes AsyncStream creation sites for cross-file termination.
    ///
    /// When Pass 1 flags an `AsyncStream.makeStream()` call, this function
    /// checks whether `continuation.finish()` or `onTermination` is set in
    /// another file.  If found, the original diagnostic is suppressed and
    /// an informational `lifecycle-stream-terminated-elsewhere` note is emitted.
    ///
    /// - Parameters:
    ///   - pass1Diagnostics: Diagnostics from Pass 1 to potentially suppress.
    ///   - streamCreationSites: Stream creation info from Pass 1.
    ///   - terminationSitesInOtherFiles: Termination sites found via the index.
    /// - Returns: Diagnostics with false positives suppressed and info notes added.
    public static func analyzeStreamTermination(
        pass1Diagnostics: [Diagnostic],
        streamCreationSites: [StreamCreationInfo],
        terminationSitesInOtherFiles: [StreamTerminationSite]
    ) -> [Diagnostic] {
        let streamRuleId = "lifecycle-unbounded-stream"

        guard !terminationSitesInOtherFiles.isEmpty else {
            // No termination sites found elsewhere; preserve all diagnostics.
            return pass1Diagnostics
        }

        // Build a set of files that have termination sites.
        let terminationFiles = Set(terminationSitesInOtherFiles.map(\.filePath))

        // Build a set of creation site files for cross-referencing.
        let creationFiles = Set(streamCreationSites.map(\.filePath))

        // Only suppress if termination exists in a file *other than* the creation file.
        let hasCrossFileTermination = terminationFiles.contains { file in
            !creationFiles.contains(file)
        }

        guard hasCrossFileTermination else {
            return pass1Diagnostics
        }

        var result: [Diagnostic] = []
        var suppressedAny = false

        for diag in pass1Diagnostics {
            if diag.ruleId == streamRuleId {
                suppressedAny = true
            } else {
                result.append(diag)
            }
        }

        if suppressedAny {
            result.append(Diagnostic(
                severity: .note,
                message: "AsyncStream termination found in another file; Pass 1 false positive suppressed",
                ruleId: "lifecycle-stream-terminated-elsewhere"
            ))
        }

        return result
    }

    // MARK: - Rule 4: Stale exemption cleanup

    /// Analyzes `// lifecycle:exempt` markers for staleness.
    ///
    /// When the underlying condition that required an exemption has been fixed
    /// (e.g., a deinit with cancel was added), the exemption marker is stale.
    /// This function emits `lifecycle-stale-exemption` info diagnostics for
    /// each stale marker.
    ///
    /// - Parameters:
    ///   - exemptionMarkers: Exemption markers collected during Pass 1.
    ///   - resolvedConditions: Conditions that have been resolved (no longer need exemption).
    /// - Returns: Info diagnostics for each stale exemption found.
    public static func analyzeStaleExemptions(
        exemptionMarkers: [ExemptionMarkerInfo],
        resolvedConditions: [ResolvedCondition]
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        for marker in exemptionMarkers {
            let isResolved = resolvedConditions.contains { condition in
                condition.ruleId == marker.suppressedRuleId
                && condition.declarationName == marker.associatedDeclarationName
                && condition.typeName == marker.typeName
            }

            if isResolved {
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "lifecycle:exempt comment for '\(marker.associatedDeclarationName)' suppressing '\(marker.suppressedRuleId)' is no longer needed; the underlying issue has been resolved",
                    filePath: marker.filePath,
                    lineNumber: marker.line,
                    columnNumber: 1,
                    ruleId: "lifecycle-stale-exemption",
                    suggestedFix: "Remove the '// lifecycle:exempt' comment."
                ))
            }
        }

        return diagnostics
    }

    // MARK: - Graceful degradation

    /// Returns a note diagnostic indicating that the index-backed pass was skipped.
    ///
    /// Used when the index store is unavailable, misconfigured, or the
    /// `useIndexStore` configuration option is disabled.  This ensures the
    /// quality gate never fails solely because of a missing index.
    ///
    /// - Returns: A `.note` severity diagnostic.
    public static func unavailableNote() -> Diagnostic {
        Diagnostic(
            severity: .note,
            message: "Memory Lifecycle Pass 2 skipped: index store unavailable. Build the project to enable cross-file lifecycle validation.",
            ruleId: "lifecycle.index-pass.skipped"
        )
    }
}
