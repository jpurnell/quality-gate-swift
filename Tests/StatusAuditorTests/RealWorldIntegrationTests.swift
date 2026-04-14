import Foundation
import Testing
@testable import StatusAuditor
@testable import QualityGateCore

/// Integration tests using real-world Master Plan patterns from actual projects.
///
/// These fixtures are snapshots from real projects that previously caused
/// false positives. Every pattern here must pass StatusAuditor without warnings.
/// If a code change causes any of these to fail, the change introduces a
/// real-world regression.
@Suite("Real-World Integration Tests")
struct RealWorldIntegrationTests {

    let config = StatusAuditorConfig()

    // MARK: - Feature-Based Master Plans (no module-per-entry)

    @Test("CoverLetterWriter: feature checklist with 24 entries, 2 actual modules")
    func coverLetterWriter() throws {
        let masterPlan = """
        ### What's Working
        - [x] Job description analysis via LLM
        - [x] Semantic skill matching with transferable skill detection
        - [x] CV filtering to relevant experiences
        - [x] Cover letter generation (single + 3 variations)
        - [x] ATS-optimized resume generation
        - [x] Dual scoring (ATS + Fit)
        - [x] Multi-format export (TXT, DOCX, PDF) with multi-page PDF support
        - [x] Application analytics tracking
        - [x] Outcome tracking and learning system
        - [x] Industry templates (6 types)
        - [x] Configuration system (portable, no hardcoded paths)
        - [x] Native Claude API client with streaming (`ClaudeClient`)
        - [x] LLM backend abstraction (`LLMClient` protocol)
        - [x] Retry logic with exponential backoff (`RetryPolicy`)
        - [x] Pipeline progress feedback (`PipelineProgress`)
        - [x] Response caching (`ResponseCache`)
        - [x] Interactive refinement with `$EDITOR` (`InteractiveSession`)
        - [x] Duplicate application detection (`DuplicateDetector`)
        - [x] Cross-application skill analytics (`SkillInsights`)
        - [x] Prompt A/B testing with statistical significance (`ABTestTracker`, `StatisticalTest`)
        - [x] Automated quality evaluation (`QualityEvaluator`)
        - [x] Comprehensive test suite (185 tests, 21 suites)
        - [x] Library/CLI architecture (`CoverLetterWriterLib` + `CoverLetterWriterCLI`)
        - [x] CLI accessible as `jdapply` command
        """

        let documented = MasterPlanParser.parseModuleStatus(from: masterPlan)
        #expect(documented.count == 24)

        // None of these feature descriptions should trigger module-marked-complete-missing
        let diags = StatusValidator.validate(
            documented: documented, actual: [:],
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        let moduleWarnings = diags.filter { $0.ruleId == "status.module-marked-complete-missing" }
        #expect(moduleWarnings.isEmpty,
                "Feature descriptions must not trigger module-missing warnings. Got: \(moduleWarnings.map(\.message))")
    }

    @Test("geo-audit: infrastructure checklist with Vapor, Docker, Stripe entries")
    func geoAudit() throws {
        let masterPlan = """
        ### What's Working
        - [x] Project scaffolded with development guidelines
        - [x] MCPClient package (StdioTransport + HTTPSSETransport, cross-platform via AsyncHTTPClient)
        - [x] WebScraper module (SwiftSoup, SitemapParser, multi-page crawl)
        - [x] GEOAuditCore orchestration (29 MCP tools, per-page + site-wide scoring)
        - [x] Vapor app with routes (auth, audit, dashboard, billing, webhooks)
        - [x] Stripe integration (Checkout for one-time, subscriptions for monitoring)
        - [x] Leaf report templates (composite scores, dimension breakdown, per-page table)
        - [x] Background job system (AuditJob + MonitoringJob via Vapor Queues + Redis)
        - [x] User auth (sessions, Bcrypt, guest accounts, email verification, password reset)
        - [x] Docker + docker-compose.production.yml (app + worker + PostgreSQL + Redis)
        - [x] Security hardening (HSTS, CSP, CORS, secure cookies, rate limiting, error pages)
        - [x] Legal pages (Terms of Service, Privacy Policy)
        - [x] Score trend charts (Chart.js composite + 6-dimension breakdown)
        - [x] Dev deployment on Starscream (10.0.1.114:8081, native Swift build)
        - [x] End-to-end pipeline verified (submit → queue → MCP scoring → report display)
        - [ ] Production deployment to geoauditors.com
        """

        let documented = MasterPlanParser.parseModuleStatus(from: masterPlan)

        let diags = StatusValidator.validate(
            documented: documented, actual: [:],
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        let moduleWarnings = diags.filter { $0.ruleId == "status.module-marked-complete-missing" }
        #expect(moduleWarnings.isEmpty,
                "Infrastructure descriptions must not trigger module-missing warnings. Got: \(moduleWarnings.map(\.message))")
    }

    @Test("iconquer: TypeScript project with non-Swift checklist items")
    func iconquer() throws {
        let masterPlan = """
        ### What's Working
        - [x] TypeScript reference implementation (`src/core/game.ts`, plugins, types)
        - [x] Original asset bundle preserved: 42 country PNGs, Background.jpg, Countries.json, Continents.json, 7 localizations under `public/maps/iconquer-world/`
        - [x] UI icons preserved under `public/ui/`
        - [x] Game rules documented in `RULES.md`
        - [x] Development-guidelines workflow scaffolded (`.claude/`, `CLAUDE.md`, project dirs)
        - [ ] Swift package skeleton — not started
        - [ ] Swift port of core engine — not started
        """

        let documented = MasterPlanParser.parseModuleStatus(from: masterPlan)

        let diags = StatusValidator.validate(
            documented: documented, actual: [:],
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        let moduleWarnings = diags.filter { $0.ruleId == "status.module-marked-complete-missing" }
        #expect(moduleWarnings.isEmpty,
                "Non-Swift feature descriptions must not trigger module-missing warnings. Got: \(moduleWarnings.map(\.message))")
    }

    // MARK: - Module-Based Master Plans (should detect real drift)

    @Test("quality-gate-swift style: PascalCase module names DO trigger when missing")
    func qualityGateStyle() throws {
        let masterPlan = """
        ### What's Working
        - [x] QualityGateCore — Protocol, models, reporters (63 tests)
        - [x] SafetyAuditor — Code safety + OWASP security (83 tests)
        - [x] GhostModule — This module does not exist
        """

        let documented = MasterPlanParser.parseModuleStatus(from: masterPlan)

        // Provide actual state for the first two but not GhostModule
        let actual: [String: ActualModuleState] = [
            "QualityGateCore": ActualModuleState(
                name: "QualityGateCore", sourceFileCount: 10,
                sourceLineCount: 500, testFileCount: 5,
                estimatedTestCount: 63, existsInPackageSwift: true
            ),
            "SafetyAuditor": ActualModuleState(
                name: "SafetyAuditor", sourceFileCount: 5,
                sourceLineCount: 1200, testFileCount: 3,
                estimatedTestCount: 83, existsInPackageSwift: true
            ),
        ]

        let diags = StatusValidator.validate(
            documented: documented, actual: actual,
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        // GhostModule SHOULD be flagged (PascalCase, looks like a module)
        let moduleWarnings = diags.filter { $0.ruleId == "status.module-marked-complete-missing" }
        #expect(moduleWarnings.count == 1)
        #expect(moduleWarnings[0].message.contains("GhostModule"))

        // The real modules should NOT produce warnings
        let allWarnings = diags.filter { $0.severity == .warning }
        #expect(allWarnings.count == 1, "Only GhostModule should produce a warning")
    }

    @Test("Template placeholders are not flagged as missing modules")
    func templatePlaceholders() {
        let masterPlan = """
        ### What's Working
        - [x] [Feature 1]
        - [x] [Feature 2]
        - [ ] [Feature 3 - in progress]
        """

        let documented = MasterPlanParser.parseModuleStatus(from: masterPlan)

        let diags = StatusValidator.validate(
            documented: documented, actual: [:],
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        let moduleWarnings = diags.filter { $0.ruleId == "status.module-marked-complete-missing" }
        #expect(moduleWarnings.isEmpty,
                "Template placeholders must not trigger module-missing warnings")
    }

    // MARK: - Mixed Master Plans

    @Test("Master Plan with both module names and feature descriptions")
    func mixedEntries() throws {
        let masterPlan = """
        ### What's Working
        - [x] WebScraper — HTML parsing and crawling
        - [x] GEOAuditCore — Orchestration engine (15 tests)
        - [x] Vapor app with routes (auth, audit, dashboard)
        - [x] Docker + PostgreSQL + Redis deployment
        - [x] GhostTarget — This does not exist
        """

        let actual: [String: ActualModuleState] = [
            "WebScraper": ActualModuleState(
                name: "WebScraper", sourceFileCount: 5,
                sourceLineCount: 1000, testFileCount: 2,
                estimatedTestCount: 10, existsInPackageSwift: true
            ),
            "GEOAuditCore": ActualModuleState(
                name: "GEOAuditCore", sourceFileCount: 8,
                sourceLineCount: 1900, testFileCount: 3,
                estimatedTestCount: 15, existsInPackageSwift: true
            ),
        ]

        let diags = StatusValidator.validate(
            documented: MasterPlanParser.parseModuleStatus(from: masterPlan),
            actual: actual,
            phases: [], lastUpdated: nil,
            masterPlanPath: "MP.md", configuration: config
        )

        let moduleWarnings = diags.filter { $0.ruleId == "status.module-marked-complete-missing" }
        // Only GhostTarget should be flagged — not "Vapor app..." or "Docker + ..."
        #expect(moduleWarnings.count == 1)
        #expect(moduleWarnings[0].message.contains("GhostTarget"))
    }
}
