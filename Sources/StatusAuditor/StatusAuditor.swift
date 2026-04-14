import Foundation
import QualityGateCore

/// Validates that project status documents match actual code state.
///
/// Detects drift between documentation (Master Plan, Implementation Checklist)
/// and reality (source files, test counts, Package.swift targets). Also implements
/// `FixableChecker` to apply surgical patches that correct provably-wrong content
/// while preserving human-authored prose.
///
/// ## Rules
///
/// | Rule ID | What it detects |
/// |---------|-----------------|
/// | `status.module-marked-incomplete` | Module has real code but checkbox says `[ ]` |
/// | `status.module-marked-complete-missing` | Checkbox says `[x]` but module doesn't exist |
/// | `status.doc-doc-conflict` | Master Plan and Checklist disagree on status |
/// | `status.test-count-drift` | Documented test count differs from actual |
/// | `status.stub-description-mismatch` | Description says "Stub only" but module is implemented |
/// | `status.roadmap-phase-stale` | Phase marked "CURRENT" but all items complete |
/// | `status.last-updated-stale` | "Last Updated" date exceeds staleness threshold |
/// | `status.phantom-module` | Roadmap references a module not in Package.swift |
///
/// ## Usage
///
/// ```bash
/// # Detect drift
/// quality-gate --check status
///
/// # Preview fixes
/// quality-gate --check status --fix --dry-run
///
/// # Apply fixes with backup
/// quality-gate --check status --fix
///
/// # Generate from scratch
/// quality-gate --check status --bootstrap
/// ```
public struct StatusAuditor: FixableChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "status"

    /// Human-readable name for this checker.
    public let name = "Status Auditor"

    /// Description of what fix mode does.
    public let fixDescription = """
    Patches Master Plan and Implementation Checklist to match actual code state:
    - Updates module completion checkboxes ([ ] → [x] or vice versa)
    - Corrects test counts to match actual test file analysis
    - Removes "Stub only" descriptions for implemented modules
    - Updates "Last Updated" date
    - Syncs Implementation Checklist with Master Plan
    Preserves all human-authored prose and project-specific context.
    """

    /// Creates a new StatusAuditor instance.
    public init() {}

    /// Run the status audit on the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath

        let guidelinesPath = (currentDir as NSString).appendingPathComponent(
            configuration.status.guidelinesPath
        )
        let masterPlanPath = (guidelinesPath as NSString).appendingPathComponent(
            configuration.status.masterPlanPath
        )

        var allDiagnostics: [Diagnostic] = []

        // Parse Master Plan if it exists
        guard fileManager.fileExists(atPath: masterPlanPath) else { // SAFETY: CLI tool reads local master plan file
            let duration = ContinuousClock.now - startTime
            return CheckResult(
                checkerId: id,
                status: .passed,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No Master Plan found at \(masterPlanPath). Skipping status audit.",
                        ruleId: "status.no-master-plan"
                    )
                ],
                duration: duration
            )
        }

        let masterPlanContent: String
        do {
            masterPlanContent = try String(contentsOfFile: masterPlanPath, encoding: .utf8)
        } catch {
            let duration = ContinuousClock.now - startTime
            return CheckResult(
                checkerId: id,
                status: .warning,
                diagnostics: [
                    Diagnostic(
                        severity: .warning,
                        message: "Could not read Master Plan: \(error.localizedDescription)",
                        file: masterPlanPath,
                        ruleId: "status.read-error"
                    )
                ],
                duration: duration
            )
        }

        // Parse documented state
        let documentedModules = MasterPlanParser.parseModuleStatus(from: masterPlanContent)
        let documentedPhases = MasterPlanParser.parseRoadmapPhases(from: masterPlanContent)
        let lastUpdated = MasterPlanParser.parseLastUpdated(from: masterPlanContent)

        // Collect actual state
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")
        let testsPath = (currentDir as NSString).appendingPathComponent("Tests")
        let packagePath = (currentDir as NSString).appendingPathComponent("Package.swift")

        let actualModules = ProjectStateCollector.collectModuleStates(
            sourcesPath: sourcesPath,
            testsPath: testsPath,
            packagePath: packagePath
        )

        // Validate
        let driftDiagnostics = StatusValidator.validate(
            documented: documentedModules,
            actual: actualModules,
            phases: documentedPhases,
            lastUpdated: lastUpdated,
            masterPlanPath: masterPlanPath,
            configuration: configuration.status
        )

        allDiagnostics.append(contentsOf: driftDiagnostics)

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.contains(where: {
            $0.severity == .error || $0.severity == .warning
        }) ? .failed : .passed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            duration: duration
        )
    }

    /// Apply fixes for the given diagnostics.
    public func fix(
        diagnostics: [Diagnostic],
        configuration: Configuration
    ) async throws -> FixResult {
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let guidelinesPath = (currentDir as NSString).appendingPathComponent(
            configuration.status.guidelinesPath
        )
        let masterPlanPath = (guidelinesPath as NSString).appendingPathComponent(
            configuration.status.masterPlanPath
        )

        guard fileManager.fileExists(atPath: masterPlanPath) else { // SAFETY: CLI tool reads local master plan file
            return FixResult(modifications: [], unfixed: diagnostics)
        }

        return try StatusRemediator.apply(
            diagnostics: diagnostics,
            masterPlanPath: masterPlanPath,
            configuration: configuration
        )
    }
}
