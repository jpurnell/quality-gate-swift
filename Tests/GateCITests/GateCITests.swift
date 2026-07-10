import Foundation
import Testing
import CorpusKit
@testable import GateCI

/// Phase 2, workstream 1 — CI identity detection.
///
/// A `CIIdentity` is only ever built from a provider's own environment
/// attestation; anything less stays an asserted identity (nil here).
@Suite("CIIdentityProbe")
struct CIIdentityProbeTests {

    private let githubEnvironment = [
        "GITHUB_ACTIONS": "true",
        "GITHUB_ACTOR": "jpurnell",
        "GITHUB_RUN_ID": "9876543210",
        "GITHUB_SHA": "abc123def456",
        "GITHUB_REPOSITORY": "jpurnell/quality-gate-swift",
    ]

    @Test("a GitHub Actions environment yields a full verified identity")
    func detectsGitHubActions() {
        let identity = CIIdentityProbe.detect(environment: githubEnvironment)
        #expect(identity == CIIdentity(
            provider: "github-actions",
            actor: "jpurnell",
            workflowRunID: "9876543210",
            commit: "abc123def456",
            repository: "jpurnell/quality-gate-swift"))
    }

    @Test("a plain local environment yields nil")
    func localIsNil() {
        #expect(CIIdentityProbe.detect(environment: [:]) == nil)
        #expect(CIIdentityProbe.detect(environment: ["CI": "true"]) == nil)
    }

    @Test("GITHUB_ACTIONS must be exactly 'true'")
    func actionsFlagMustBeTrue() {
        var env = githubEnvironment
        env["GITHUB_ACTIONS"] = "1"
        #expect(CIIdentityProbe.detect(environment: env) == nil)
    }

    @Test("a partial GitHub environment is not a verified identity")
    func partialEnvironmentIsNil() {
        for missing in ["GITHUB_ACTOR", "GITHUB_RUN_ID", "GITHUB_SHA", "GITHUB_REPOSITORY"] {
            var env = githubEnvironment
            env.removeValue(forKey: missing)
            #expect(CIIdentityProbe.detect(environment: env) == nil,
                    "identity built despite missing \(missing)")
        }
    }
}

/// Phase 2, workstream 1 — the canonical CI invocation.
///
/// `quality-gate ci` wraps the standard run; the plan below IS the parity
/// contract: every input that could differ between two runs of the same
/// commit is forced to a declared state.
@Suite("CIRunPlan")
struct CIRunPlanTests {

    @Test("defaults force determinism: no index build, no cache, strict, UTC")
    func deterministicDefaults() {
        let plan = CIRunPlan()
        #expect(plan.gateArguments.contains("--no-index-build"))
        #expect(plan.gateArguments.contains("--no-cache"))
        #expect(plan.gateArguments.contains("--strict"))
        #expect(plan.gateArguments.contains("--continue-on-failure"))
        #expect(plan.environmentOverrides["TZ"] == "UTC")
    }

    @Test("machine-readable outputs are on by default")
    func machineReadableOutputs() {
        let plan = CIRunPlan(outputDirectory: "/artifacts")
        let args = plan.gateArguments
        guard let sarifIndex = args.firstIndex(of: "--sarif-output"),
              sarifIndex + 1 < args.count,
              let summaryIndex = args.firstIndex(of: "--summary-output"),
              summaryIndex + 1 < args.count else {
            Issue.record("missing --sarif-output/--summary-output in \(args)")
            return
        }
        #expect(args[sarifIndex + 1] == "/artifacts/quality-gate.sarif")
        #expect(args[summaryIndex + 1] == "/artifacts/quality-gate-summary.json")
    }

    @Test("index use is deliberate: opt-in build clears --no-index-build")
    func indexOptIn() {
        let plan = CIRunPlan(indexMode: .build)
        #expect(!plan.gateArguments.contains("--no-index-build"))
    }

    @Test("strict can be disabled explicitly, never implicitly")
    func strictOptOut() {
        let plan = CIRunPlan(strict: false)
        #expect(!plan.gateArguments.contains("--strict"))
        // The determinism flags survive regardless.
        #expect(plan.gateArguments.contains("--no-cache"))
    }

    @Test("the plan is stable — same inputs, byte-identical arguments")
    func planIsDeterministic() {
        let first = CIRunPlan(indexMode: .none, outputDirectory: "/a", strict: true)
        let second = CIRunPlan(indexMode: .none, outputDirectory: "/a", strict: true)
        #expect(first.gateArguments == second.gateArguments)
        #expect(first == second)
    }
}
