import Foundation
import Testing
@testable import QualityGateCore

/// Tests for `CheckerProfile`, which derives membership from what a checker declares.
///
/// Membership was first drafted as a list of ids maintained beside the registry. Both spellings
/// of that list fail silently and in opposite directions: an inclusion list drops a newly added
/// checker out of every profile, an exclusion list quietly admits a new documentation checker
/// into `code`. Deriving from ``CheckerKind`` and ``CheckerEffect`` — neither of which has a
/// default — removes the second source of truth, so a profile cannot drift from the registry.
@Suite("CheckerProfile")
struct CheckerProfileTests {

    private struct Stub: QualityChecker {
        let id: String
        let name = "Stub"
        let summary = "A stand-in checker"
        let category = CheckerCategory.correctness
        let kind: CheckerKind
        let effect: CheckerEffect
        let hermeticity = Hermeticity.hermetic
        func check(configuration: Configuration) async throws -> CheckResult {
            CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
        }
    }

    /// Deliberately mixed: every kind, and a writer that is otherwise code-shaped.
    private let registry: [any QualityChecker] = [
        Stub(id: "safety", kind: .code, effect: .readOnly),
        Stub(id: "concurrency", kind: .code, effect: .readOnly),
        Stub(id: "test-quality", kind: .code, effect: .readOnly),
        Stub(id: "doc-lint", kind: .documentation, effect: .readOnly),
        Stub(id: "doc-code", kind: .documentation, effect: .readOnly),
        Stub(id: "custom-rules", kind: .convention, effect: .readOnly),
        Stub(id: "hig-auditor", kind: .convention, effect: .readOnly),
        Stub(id: "consistency", kind: .institutional, effect: .readOnly),
        Stub(id: "memory-builder", kind: .convention, effect: .writesOutsideTree),
        Stub(id: "hypothetical-writer", kind: .code, effect: .writesTree),
    ]

    // MARK: - code

    @Test("code selects code-kind checkers")
    func codeSelectsCode() {
        let ids = Set(CheckerProfile.code.checkerIDs(from: registry))
        #expect(ids.contains("safety"))
        #expect(ids.contains("concurrency"))
    }

    /// Decided 2026-08-16. The case against including it was its false positives, and all eight
    /// in the Coalesced run came from `missing-assertion` — a rule with its own proposal to fix.
    /// Excluding the checker would treat the symptom and hide the evidence that produced the
    /// fix: a survey that drops the noisy checkers can never learn why they are noisy.
    @Test("code includes test-quality")
    func codeIncludesTestQuality() {
        #expect(CheckerProfile.code.checkerIDs(from: registry).contains("test-quality"))
    }

    @Test("code excludes documentation, convention and institutional kinds")
    func codeExcludesOtherKinds() {
        let ids = Set(CheckerProfile.code.checkerIDs(from: registry))
        for excluded in ["doc-lint", "doc-code", "custom-rules", "hig-auditor", "consistency"] {
            #expect(!ids.contains(excluded))
        }
    }

    /// The second axis, and the one a taxonomy alone would miss. A checker can judge code
    /// correctly and still write — `memory-builder` leaves a memory directory keyed on the
    /// project's absolute path, so a survey of thirty repositories leaves thirty of them.
    @Test("code excludes anything that writes, whatever it judges")
    func codeExcludesWriters() {
        let ids = Set(CheckerProfile.code.checkerIDs(from: registry))
        #expect(!ids.contains("memory-builder"))
        // Code-kind *and* a writer: excluded on effect alone. This is the case a kind-only
        // filter would wrongly admit.
        #expect(!ids.contains("hypothetical-writer"))
    }

    @Test("code preserves registry order")
    func codePreservesOrder() {
        let ids = CheckerProfile.code.checkerIDs(from: registry)
        #expect(ids == ["safety", "concurrency", "test-quality"])
    }

    // MARK: - docs

    @Test("docs selects documentation checkers and nothing else")
    func docsSelectsDocumentation() {
        let ids = Set(CheckerProfile.docs.checkerIDs(from: registry))
        #expect(ids == ["doc-lint", "doc-code"])
    }

    /// `code` and `docs` do not partition the registry, and must not: convention and
    /// institutional checkers belong to neither, which is exactly why reusing the two-way
    /// documentation/other split would have been wrong.
    @Test("code and docs are disjoint and jointly incomplete")
    func profilesAreDisjointAndIncomplete() {
        let code = Set(CheckerProfile.code.checkerIDs(from: registry))
        let docs = Set(CheckerProfile.docs.checkerIDs(from: registry))
        #expect(code.isDisjoint(with: docs))
        let covered = code.union(docs)
        #expect(!covered.contains("consistency"))
        #expect(!covered.contains("hig-auditor"))
    }

    // MARK: - all

    @Test("all selects everything, including writers")
    func allSelectsEverything() {
        #expect(CheckerProfile.all.checkerIDs(from: registry) == registry.map(\.id))
    }

    // MARK: - Explaining the gap

    /// A profile that silently runs 3 of 10 invites "where did the rest go?", and the answer is
    /// more useful than the count.
    @Test("exclusion reasons name the axis that excluded the checker")
    func exclusionReasonsAreSpecific() {
        guard let writer = registry.first(where: { $0.id == "memory-builder" }),
              let institutional = registry.first(where: { $0.id == "consistency" }),
              let included = registry.first(where: { $0.id == "safety" }) else {
            Issue.record("fixture registry is missing an expected stub")
            return
        }
        #expect(CheckerProfile.code.exclusionReason(for: writer)?.contains("writes") == true)
        #expect(CheckerProfile.code.exclusionReason(for: institutional)?.contains("institutional") == true)
        #expect(CheckerProfile.code.exclusionReason(for: included) == nil)
    }

    // MARK: - Parsing

    /// An unknown profile must not resolve. That failure has shipped here once already:
    /// `enabledCheckers: [all]` matched no checker id, ran nothing, and printed PASSED.
    @Test("an unknown profile name does not resolve")
    func unknownProfileDoesNotResolve() {
        #expect(CheckerProfile(rawValue: "cod") == nil)
        #expect(CheckerProfile(rawValue: "") == nil)
        #expect(CheckerProfile(rawValue: "code") == .code)
    }
}
