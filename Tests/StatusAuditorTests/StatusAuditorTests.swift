import Foundation
import Testing
@testable import StatusAuditor
@testable import QualityGateCore

// MARK: - MasterPlanParser Tests

@Suite("MasterPlanParser Tests")
struct MasterPlanParserTests {

    // MARK: - Module Status Parsing

    @Test("Parses complete checkbox entry")
    func parsesCompleteCheckbox() {
        let content = """
        ### What's Working
        - [x] SafetyAuditor — Code safety + OWASP security (83 tests)
        """

        let modules = MasterPlanParser.parseModuleStatus(from: content)
        #expect(modules.count == 1)
        #expect(modules[0].name == "SafetyAuditor")
        #expect(modules[0].isComplete == true)
        #expect(modules[0].description == "Code safety + OWASP security (83 tests)")
        #expect(modules[0].claimedTestCount == 83)
    }

    @Test("Parses incomplete checkbox entry")
    func parsesIncompleteCheckbox() {
        let content = """
        ### What's Working
        - [ ] FooChecker — Stub only
        """

        let modules = MasterPlanParser.parseModuleStatus(from: content)
        #expect(modules.count == 1)
        #expect(modules[0].name == "FooChecker")
        #expect(modules[0].isComplete == false)
        #expect(modules[0].description == "Stub only")
        #expect(modules[0].claimedTestCount == nil)
    }

    @Test("Parses multiple module entries")
    func parsesMultipleEntries() {
        let content = """
        ### What's Working
        - [x] QualityGateCore — Protocol, models, reporters (54 tests)
        - [x] SafetyAuditor — Code safety (83 tests)
        - [ ] FooChecker — Stub only
        - [x] BuildChecker — swift build wrapper
        """

        let modules = MasterPlanParser.parseModuleStatus(from: content)
        #expect(modules.count == 4)
        #expect(modules[0].name == "QualityGateCore")
        #expect(modules[2].name == "FooChecker")
        #expect(modules[2].isComplete == false)
    }

    @Test("Stops parsing at next heading")
    func stopsAtNextHeading() {
        let content = """
        ### What's Working
        - [x] ModuleA — Complete
        ### Known Issues
        - [ ] This is not a module — this is an issue
        """

        let modules = MasterPlanParser.parseModuleStatus(from: content)
        #expect(modules.count == 1)
        #expect(modules[0].name == "ModuleA")
    }

    @Test("Extracts test count from various formats")
    func extractsTestCounts() {
        #expect(MasterPlanParser.parseTestCount(from: "(54 tests)") == 54)
        #expect(MasterPlanParser.parseTestCount(from: "(1 test)") == 1)
        #expect(MasterPlanParser.parseTestCount(from: "Protocol, models (465 tests)") == 465)
        #expect(MasterPlanParser.parseTestCount(from: "Stub only") == nil)
        #expect(MasterPlanParser.parseTestCount(from: "No test info") == nil)
    }

    @Test("Returns empty for content with no status section")
    func emptyForNoStatusSection() {
        let content = """
        # Master Plan
        Some other content here.
        """

        let modules = MasterPlanParser.parseModuleStatus(from: content)
        #expect(modules.isEmpty)
    }

    // MARK: - Roadmap Phase Parsing

    @Test("Parses phase with COMPLETE label")
    func parsesCompletePhase() {
        let content = """
        ## Roadmap

        ### Phase 1: Foundation (COMPLETE)
        - [x] QualityGateCore module with tests
        - [x] SafetyAuditor implementation
        """

        let phases = MasterPlanParser.parseRoadmapPhases(from: content)
        #expect(phases.count == 1)
        #expect(phases[0].label == "COMPLETE")
        #expect(phases[0].items.count == 2)
        #expect(phases[0].allItemsComplete == true)
    }

    @Test("Parses phase with CURRENT label and mixed items")
    func parsesCurrentPhase() {
        let content = """
        ## Roadmap

        ### Phase 2: Checkers (CURRENT)
        - [x] BuildChecker implementation
        - [ ] DocLinter implementation
        """

        let phases = MasterPlanParser.parseRoadmapPhases(from: content)
        #expect(phases.count == 1)
        #expect(phases[0].label == "CURRENT")
        #expect(phases[0].allItemsComplete == false)
    }

    @Test("Detects stale CURRENT phase where all items are complete")
    func detectsStaleCurrentPhase() {
        let content = """
        ## Roadmap

        ### Phase 1: Foundation (CURRENT)
        - [x] Item A
        - [x] Item B
        - [x] Item C
        """

        let phases = MasterPlanParser.parseRoadmapPhases(from: content)
        #expect(phases[0].label == "CURRENT")
        #expect(phases[0].allItemsComplete == true)
    }

    @Test("Parses multiple phases")
    func parsesMultiplePhases() {
        let content = """
        ## Roadmap

        ### Phase 1: Foundation (COMPLETE)
        - [x] Core module

        ### Phase 2: Checkers (CURRENT)
        - [x] Safety
        - [ ] Docs

        ### Phase 3: CLI (PLANNED)
        - [ ] CLI tool
        """

        let phases = MasterPlanParser.parseRoadmapPhases(from: content)
        #expect(phases.count == 3)
    }

    // MARK: - Last Updated Parsing

    @Test("Parses Last Updated date")
    func parsesLastUpdated() {
        let content = """
        Some content

        **Last Updated:** 2026-04-14
        """

        let result = MasterPlanParser.parseLastUpdated(from: content)
        #expect(result?.date == "2026-04-14")
        #expect(result?.line == 3)
    }

    @Test("Returns nil when no Last Updated present")
    func nilWhenNoLastUpdated() {
        let content = "# Master Plan\nNo date here."
        let result = MasterPlanParser.parseLastUpdated(from: content)
        #expect(result == nil)
    }
}

// MARK: - ProjectStateCollector Tests

@Suite("ProjectStateCollector Tests")
struct ProjectStateCollectorTests {

    @Test("Parses target names from Package.swift content")
    func parsesPackageTargets() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packageContent = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "TestProject",
            targets: [
                .target(name: "ModuleA"),
                .target(name: "ModuleB"),
                .testTarget(name: "ModuleATests"),
                .executableTarget(name: "CLI"),
            ]
        )
        """

        let packagePath = tmpDir.appendingPathComponent("Package.swift")
        try packageContent.write(to: packagePath, atomically: true, encoding: .utf8)

        let targets = ProjectStateCollector.parsePackageTargets(at: packagePath.path)
        #expect(targets.contains("ModuleA"))
        #expect(targets.contains("ModuleB"))
        #expect(targets.contains("ModuleATests"))
        #expect(targets.contains("CLI"))
        #expect(targets.count == 4)
    }

    @Test("Counts Swift files and lines")
    func countsSwiftFiles() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "line1\nline2\nline3\n".write(
            to: tmpDir.appendingPathComponent("a.swift"),
            atomically: true, encoding: .utf8
        )
        try "line1\nline2\n".write(
            to: tmpDir.appendingPathComponent("b.swift"),
            atomically: true, encoding: .utf8
        )
        try "not swift".write(
            to: tmpDir.appendingPathComponent("c.txt"),
            atomically: true, encoding: .utf8
        )

        let (fileCount, lineCount) = ProjectStateCollector.countSwiftFiles(at: tmpDir.path)
        #expect(fileCount == 2)
        #expect(lineCount >= 5) // At least 5 lines across 2 files
    }

    @Test("Counts test occurrences")
    func countsTestOccurrences() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let testContent = """
        import Testing

        @Test("First test")
        func firstTest() { }

        @Test("Second test")
        func secondTest() { }

        func testThirdXCTest() { }
        """

        try testContent.write(
            to: tmpDir.appendingPathComponent("MyTests.swift"),
            atomically: true, encoding: .utf8
        )

        let count = ProjectStateCollector.countTestOccurrences(at: tmpDir.path)
        #expect(count == 3) // 2 @Test + 1 func test*
    }

    @Test("Returns zero for nonexistent directory")
    func zeroForMissingDir() {
        let (files, lines) = ProjectStateCollector.countSwiftFiles(at: "/nonexistent/path")
        #expect(files == 0)
        #expect(lines == 0)
    }
}

// MARK: - StatusValidator Tests

@Suite("StatusValidator Tests")
struct StatusValidatorTests {

    let config = StatusAuditorConfig()

    @Test("Flags module marked incomplete with real code")
    func flagsIncompleteWithCode() {
        let documented = [
            DocumentedModuleStatus(
                name: "SafetyAuditor", isComplete: false,
                description: "Stub only", claimedTestCount: nil, line: 5
            )
        ]
        let actual = [
            "SafetyAuditor": ActualModuleState(
                name: "SafetyAuditor", sourceFileCount: 3,
                sourceLineCount: 500, testFileCount: 1,
                estimatedTestCount: 20, existsInPackageSwift: true
            )
        ]

        let diags = StatusValidator.validate(
            documented: documented, actual: actual,
            phases: [], lastUpdated: nil,
            masterPlanPath: "MASTER_PLAN.md", configuration: config
        )

        #expect(diags.contains { $0.ruleId == "status.module-marked-incomplete" })
        #expect(diags.contains { $0.ruleId == "status.stub-description-mismatch" })
    }

    @Test("Does not flag module marked incomplete with tiny code")
    func doesNotFlagTinyModule() {
        let documented = [
            DocumentedModuleStatus(
                name: "Stub", isComplete: false,
                description: "Stub only", claimedTestCount: nil, line: 5
            )
        ]
        let actual = [
            "Stub": ActualModuleState(
                name: "Stub", sourceFileCount: 1,
                sourceLineCount: 10, testFileCount: 0,
                estimatedTestCount: 0, existsInPackageSwift: true
            )
        ]

        let diags = StatusValidator.validate(
            documented: documented, actual: actual,
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(!diags.contains { $0.ruleId == "status.module-marked-incomplete" })
    }

    @Test("Flags module marked complete but missing")
    func flagsCompleteMissing() {
        let documented = [
            DocumentedModuleStatus(
                name: "GhostModule", isComplete: true,
                description: "Complete", claimedTestCount: nil, line: 5
            )
        ]

        let diags = StatusValidator.validate(
            documented: documented, actual: [:],
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(diags.contains { $0.ruleId == "status.module-marked-complete-missing" })
    }

    @Test("Flags test count drift")
    func flagsTestCountDrift() {
        let documented = [
            DocumentedModuleStatus(
                name: "Core", isComplete: true,
                description: "Protocol, models (54 tests)", claimedTestCount: 54, line: 5
            )
        ]
        let actual = [
            "Core": ActualModuleState(
                name: "Core", sourceFileCount: 10,
                sourceLineCount: 2000, testFileCount: 5,
                estimatedTestCount: 200, existsInPackageSwift: true
            )
        ]

        let diags = StatusValidator.validate(
            documented: documented, actual: actual,
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(diags.contains { $0.ruleId == "status.test-count-drift" })
    }

    @Test("Does not flag small test count drift")
    func doesNotFlagSmallDrift() {
        let documented = [
            DocumentedModuleStatus(
                name: "Core", isComplete: true,
                description: "(50 tests)", claimedTestCount: 50, line: 5
            )
        ]
        let actual = [
            "Core": ActualModuleState(
                name: "Core", sourceFileCount: 5,
                sourceLineCount: 500, testFileCount: 2,
                estimatedTestCount: 52, existsInPackageSwift: true
            )
        ]

        let diags = StatusValidator.validate(
            documented: documented, actual: actual,
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(!diags.contains { $0.ruleId == "status.test-count-drift" })
    }

    @Test("Flags stale roadmap phase")
    func flagsStalePhase() {
        let phases = [
            DocumentedPhase(
                name: "Phase 1: Foundation",
                label: "CURRENT",
                items: [("Core module", true), ("Safety implementation", true)],
                line: 50
            )
        ]

        let diags = StatusValidator.validate(
            documented: [], actual: [:],
            phases: phases, lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(diags.contains { $0.ruleId == "status.roadmap-phase-stale" })
    }

    @Test("Does not flag CURRENT phase with incomplete items")
    func doesNotFlagActivePhase() {
        let phases = [
            DocumentedPhase(
                name: "Phase 2: Checkers",
                label: "CURRENT",
                items: [("BuildChecker", true), ("DocLinter", false)],
                line: 60
            )
        ]

        let diags = StatusValidator.validate(
            documented: [], actual: [:],
            phases: phases, lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(!diags.contains { $0.ruleId == "status.roadmap-phase-stale" })
    }

    @Test("Flags stale Last Updated date")
    func flagsStaleLastUpdated() {
        // 200 days ago (threshold is 90)
        let calendar = Calendar.current
        let oldDate = calendar.date(byAdding: .day, value: -200, to: .now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let dateStr = formatter.string(from: oldDate ?? .now)

        let diags = StatusValidator.validate(
            documented: [], actual: [:],
            phases: [],
            lastUpdated: (date: dateStr, line: 100),
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(diags.contains { $0.ruleId == "status.last-updated-stale" })
    }

    @Test("Does not flag recent Last Updated date")
    func doesNotFlagRecentDate() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let today = formatter.string(from: .now)

        let diags = StatusValidator.validate(
            documented: [], actual: [:],
            phases: [],
            lastUpdated: (date: today, line: 100),
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(!diags.contains { $0.ruleId == "status.last-updated-stale" })
    }

    @Test("Passes when everything matches")
    func passesWhenCorrect() {
        let documented = [
            DocumentedModuleStatus(
                name: "ModuleA", isComplete: true,
                description: "Complete (10 tests)", claimedTestCount: 10, line: 5
            )
        ]
        let actual = [
            "ModuleA": ActualModuleState(
                name: "ModuleA", sourceFileCount: 5,
                sourceLineCount: 200, testFileCount: 1,
                estimatedTestCount: 10, existsInPackageSwift: true
            )
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let today = formatter.string(from: .now)

        let diags = StatusValidator.validate(
            documented: documented, actual: actual,
            phases: [],
            lastUpdated: (date: today, line: 100),
            masterPlanPath: "MP.md", configuration: config
        )

        let warnings = diags.filter { $0.severity == .warning || $0.severity == .error }
        #expect(warnings.isEmpty)
    }

    // MARK: - Module Name Heuristic Tests

    @Test("looksLikeModuleName: PascalCase identifiers are modules")
    func pascalCaseIsModule() {
        #expect(StatusValidator.looksLikeModuleName("SafetyAuditor"))
        #expect(StatusValidator.looksLikeModuleName("QualityGateCore"))
        #expect(StatusValidator.looksLikeModuleName("BuildChecker"))
        #expect(StatusValidator.looksLikeModuleName("IgniteCLI"))
    }

    @Test("looksLikeModuleName: lowercase identifiers are modules")
    func lowercaseIsModule() {
        #expect(StatusValidator.looksLikeModuleName("vapor"))
        #expect(StatusValidator.looksLikeModuleName("swift-syntax"))
    }

    @Test("looksLikeModuleName: feature descriptions are NOT modules")
    func featureDescriptionsAreNotModules() {
        #expect(!StatusValidator.looksLikeModuleName("Job description analysis via LLM"))
        #expect(!StatusValidator.looksLikeModuleName("Docker + docker-compose"))
        #expect(!StatusValidator.looksLikeModuleName("All three reporters"))
        #expect(!StatusValidator.looksLikeModuleName("CLI accessible as `jdapply` command"))
        #expect(!StatusValidator.looksLikeModuleName("Stripe integration (Checkout for one-time, subscriptions)"))
        #expect(!StatusValidator.looksLikeModuleName("SPM CommandPlugin"))
        #expect(!StatusValidator.looksLikeModuleName("[Feature 1]"))
    }

    @Test("Does not flag feature descriptions as missing modules")
    func doesNotFlagFeatureDescriptions() {
        let documented = [
            DocumentedModuleStatus(
                name: "Job description analysis via LLM", isComplete: true,
                description: "Complete", claimedTestCount: nil, line: 5
            ),
            DocumentedModuleStatus(
                name: "Docker + Redis setup", isComplete: true,
                description: "Complete", claimedTestCount: nil, line: 6
            ),
            DocumentedModuleStatus(
                name: "[Feature 1]", isComplete: true,
                description: "Complete", claimedTestCount: nil, line: 7
            ),
        ]

        let diags = StatusValidator.validate(
            documented: documented, actual: [:],
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(!diags.contains { $0.ruleId == "status.module-marked-complete-missing" })
    }

    @Test("Still flags PascalCase module names as missing")
    func stillFlagsModuleNames() {
        let documented = [
            DocumentedModuleStatus(
                name: "GhostModule", isComplete: true,
                description: "Complete", claimedTestCount: nil, line: 5
            ),
        ]

        let diags = StatusValidator.validate(
            documented: documented, actual: [:],
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        #expect(diags.contains { $0.ruleId == "status.module-marked-complete-missing" })
    }
}

// MARK: - StatusAuditor Identity Tests

@Suite("StatusAuditor Identity Tests")
struct StatusAuditorIdentityTests {

    @Test("StatusAuditor has correct id and name")
    func checkerIdentity() {
        let auditor = StatusAuditor()
        #expect(auditor.id == "status")
        #expect(auditor.name == "Status Auditor")
    }

    @Test("StatusAuditor has fix description")
    func hasFixDescription() {
        let auditor = StatusAuditor()
        #expect(!auditor.fixDescription.isEmpty)
        #expect(auditor.fixDescription.contains("checkbox"))
    }
}

// MARK: - StatusRemediator Tests

@Suite("StatusRemediator Tests")
struct StatusRemediatorTests {

    @Test("Flips incomplete checkbox to complete")
    func flipsCheckbox() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let content = "- [ ] SafetyAuditor — Stub only\n"
        let path = tmpDir.appendingPathComponent("MP.md")
        try content.write(to: path, atomically: true, encoding: .utf8)

        let diag = Diagnostic(
            severity: .warning,
            message: "Marked incomplete",
            file: path.path,
            line: 1,
            ruleId: "status.module-marked-incomplete"
        )

        let result = try StatusRemediator.apply(
            diagnostics: [diag],
            masterPlanPath: path.path,
            configuration: Configuration()
        )

        #expect(result.hasChanges)
        #expect(result.modifications.count == 1)
        #expect(result.modifications[0].backupPath != nil)

        let patched = try String(contentsOf: path, encoding: .utf8)
        #expect(patched.contains("- [x] SafetyAuditor"))
    }

    @Test("Replaces CURRENT with COMPLETE for stale phase")
    func replacesCurrentWithComplete() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let content = "### Phase 1: Foundation (CURRENT)\n"
        let path = tmpDir.appendingPathComponent("MP.md")
        try content.write(to: path, atomically: true, encoding: .utf8)

        let diag = Diagnostic(
            severity: .warning,
            message: "Phase stale",
            file: path.path,
            line: 1,
            ruleId: "status.roadmap-phase-stale"
        )

        let result = try StatusRemediator.apply(
            diagnostics: [diag],
            masterPlanPath: path.path,
            configuration: Configuration()
        )

        let patched = try String(contentsOf: path, encoding: .utf8)
        #expect(patched.contains("(COMPLETE)"))
        #expect(!patched.contains("(CURRENT)"))
    }

    @Test("Moves unfixable diagnostics to unfixed list")
    func movesUnfixableToUnfixed() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let content = "Some content\n"
        let path = tmpDir.appendingPathComponent("MP.md")
        try content.write(to: path, atomically: true, encoding: .utf8)

        let diag = Diagnostic(
            severity: .warning,
            message: "Phantom module",
            ruleId: "status.phantom-module"
        )

        let result = try StatusRemediator.apply(
            diagnostics: [diag],
            masterPlanPath: path.path,
            configuration: Configuration()
        )

        #expect(!result.hasChanges)
        #expect(result.unfixed.count == 1)
    }

    @Test("Creates timestamped backup before modifying")
    func createsBackup() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let content = "- [ ] Module — Stub only\n"
        let path = tmpDir.appendingPathComponent("MP.md")
        try content.write(to: path, atomically: true, encoding: .utf8)

        let diag = Diagnostic(
            severity: .warning, message: "Incomplete",
            file: path.path, line: 1,
            ruleId: "status.module-marked-incomplete"
        )

        let result = try StatusRemediator.apply(
            diagnostics: [diag],
            masterPlanPath: path.path,
            configuration: Configuration()
        )

        guard let backupPath = result.modifications.first?.backupPath else {
            Issue.record("No backup path in modification")
            return
        }

        #expect(FileManager.default.fileExists(atPath: backupPath))
        let backup = try String(contentsOfFile: backupPath, encoding: .utf8)
        #expect(backup.contains("- [ ] Module"))
    }
}

// MARK: - StatusBootstrapper Tests

@Suite("StatusBootstrapper Tests")
struct StatusBootstrapperTests {

    @Test("Generates Master Plan from project with modules")
    func generatesFromProject() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sourcesDir = tmpDir.appendingPathComponent("Sources")
        let moduleDir = sourcesDir.appendingPathComponent("MyModule")
        let testsDir = tmpDir.appendingPathComponent("Tests")
        let testModuleDir = testsDir.appendingPathComponent("MyModuleTests")

        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testModuleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create Package.swift
        let packageContent = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "TestProject",
            targets: [
                .target(name: "MyModule"),
                .testTarget(name: "MyModuleTests"),
            ]
        )
        """
        try packageContent.write(
            to: tmpDir.appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8
        )

        // Create source files (>50 lines to pass stub threshold)
        let sourceContent = (0..<60).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        try sourceContent.write(
            to: moduleDir.appendingPathComponent("Source.swift"),
            atomically: true, encoding: .utf8
        )

        // Create test file
        let testContent = """
        import Testing
        @Test("Test one") func testOne() { }
        @Test("Test two") func testTwo() { }
        """
        try testContent.write(
            to: testModuleDir.appendingPathComponent("Tests.swift"),
            atomically: true, encoding: .utf8
        )

        let content = StatusBootstrapper.generate(
            projectRoot: tmpDir.path,
            configuration: Configuration()
        )

        #expect(content.contains("# TestProject Master Plan"))
        #expect(content.contains("- [x] MyModule"))
        #expect(content.contains("Last Updated"))
        #expect(content.contains("<!-- TODO"))
    }

    @Test("Generates minimal plan for empty project")
    func generatesForEmptyProject() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packageContent = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "EmptyProject", targets: [])
        """
        try packageContent.write(
            to: tmpDir.appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8
        )

        let content = StatusBootstrapper.generate(
            projectRoot: tmpDir.path,
            configuration: Configuration()
        )

        #expect(content.contains("# EmptyProject Master Plan"))
        #expect(content.contains("Total: 0 estimated tests"))
    }

    @Test("Excludes test targets and plugins from module list")
    func excludesTestsAndPlugins() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sourcesDir = tmpDir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(
            at: sourcesDir.appendingPathComponent("MyModule"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sourcesDir.appendingPathComponent("MyPlugin"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packageContent = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Test",
            targets: [
                .target(name: "MyModule"),
                .testTarget(name: "MyModuleTests"),
            ]
        )
        """
        try packageContent.write(
            to: tmpDir.appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8
        )

        // Add enough source to pass threshold
        let source = (0..<60).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        try source.write(
            to: sourcesDir.appendingPathComponent("MyModule/Source.swift"),
            atomically: true, encoding: .utf8
        )

        let content = StatusBootstrapper.generate(
            projectRoot: tmpDir.path,
            configuration: Configuration()
        )

        #expect(content.contains("MyModule"))
        #expect(!content.contains("MyModuleTests"))
    }
}
