import Foundation
import IndexStoreInfra
import QualityGateCore
import Testing
@testable import UnreachableCodeAuditor

/// Tests the barrier that replaces cross-module findings when the index cannot be trusted.
///
/// A stale index produced an error naming a symbol that had been deleted minutes earlier, at
/// a line whose contents were unrelated to it. The same report named two live symbols as dead;
/// they were nearly deleted on its authority, and were spared only because the deleted symbol
/// appeared alongside them and gave the staleness away. A diagnostic that is wrong and
/// indistinguishable from a correct one spends the reader's trust rather than their time.
@Suite("Unreachable index barrier")
struct IndexBarrierTests {

    private static let indexBuilt = Date(timeIntervalSince1970: 1_755_000_000)
    private static let sourceEdited = Date(timeIntervalSince1970: 1_755_200_000)

    private let store = URL(fileURLWithPath: "/tmp/pkg/.build/index-build/index-store")

    private func located(_ measurement: IndexFreshnessMeasurement) -> StoreLocator.LocatedStore {
        StoreLocator.LocatedStore(url: store, measurement: measurement)
    }

    private var staleFreshness: IndexFreshness {
        IndexFreshness(
            newestSource: Self.sourceEdited,
            newestIndexUnit: Self.indexBuilt,
            unitCount: 1_284
        )
    }

    @Test("A stale index yields a barrier instead of findings")
    func staleIndexYieldsBarrier() {
        let outcome = UnreachableCodeAuditor.indexProvenance(located: located(.measured(staleFreshness)))

        #expect(outcome.shouldRun == false)
        #expect(outcome.diagnostics.count == 1)
        guard let barrier = outcome.diagnostics.first else {
            Issue.record("expected a barrier diagnostic")
            return
        }
        #expect(barrier.severity == .error)
        #expect(barrier.ruleId == "unreachable.index.stale-barrier")
        #expect(barrier.message.contains("reachability"))
    }

    /// The hint is load-bearing. `--no-cache` is the flag a reader reaches for when a result
    /// looks stale, and it re-runs the checker against the same index — a different artefact
    /// with a different lifetime. Saying so at the point of failure is the difference between
    /// a two-minute fix and the investigation that produced this checker.
    @Test("The barrier names --no-cache as the flag that does not help")
    func barrierNamesTheUselessFlag() {
        let outcome = UnreachableCodeAuditor.indexProvenance(located: located(.measured(staleFreshness)))

        guard let fix = outcome.diagnostics.first?.suggestedFix else {
            Issue.record("expected a suggested fix")
            return
        }
        #expect(fix.contains("--no-cache"))
        #expect(fix.contains("swift build"))
    }

    /// Both timestamps, not one. A barrier saying only "the index is stale" leaves the reader
    /// unable to tell a two-minute drift from a five-day one, which is the difference between
    /// "rebuild and move on" and "something is wrong with how this project builds".
    ///
    /// The expected strings are rendered here with the same format rather than hardcoded,
    /// because a hardcoded rendering would encode this machine's timezone. What is under test
    /// is that both dates reach the message and remain distinct — the failure mode being one
    /// date quoted twice.
    @Test("The barrier carries both timestamps so the reader can date the drift")
    func barrierCarriesBothTimestamps() {
        let outcome = UnreachableCodeAuditor.indexProvenance(located: located(.measured(staleFreshness)))

        guard let message = outcome.diagnostics.first?.message else {
            Issue.record("expected a barrier diagnostic")
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let indexStamp = formatter.string(from: Self.indexBuilt)
        let sourceStamp = formatter.string(from: Self.sourceEdited)

        #expect(indexStamp != sourceStamp)
        #expect(message.contains(indexStamp))
        #expect(message.contains(sourceStamp))
    }

    /// An index with no units cannot date itself — but far worse, running the reachability
    /// pass against it finds no references at all, so every symbol in the package looks dead.
    /// That is a larger false-positive surface than the stale case, and it must not be
    /// reported as staleness, because the timestamps that sentence would quote do not exist.
    @Test("An index with no units is a barrier of its own, not a stale-index report")
    func emptyIndexIsItsOwnBarrier() {
        let outcome = UnreachableCodeAuditor.indexProvenance(located: located(.noIndexUnits))

        #expect(outcome.shouldRun == false)
        guard let barrier = outcome.diagnostics.first else {
            Issue.record("expected a barrier diagnostic")
            return
        }
        #expect(barrier.severity == .error)
        #expect(barrier.ruleId == "unreachable.index.unmeasurable")
    }

    @Test("A fresh index runs, and states its age and size on the way past")
    func freshIndexRunsAndReportsProvenance() {
        let fresh = IndexFreshness(
            newestSource: Self.indexBuilt,
            newestIndexUnit: Self.sourceEdited,
            unitCount: 1_284
        )
        let outcome = UnreachableCodeAuditor.indexProvenance(located: located(.measured(fresh)))

        #expect(outcome.shouldRun)
        guard let note = outcome.diagnostics.first else {
            Issue.record("expected a provenance note")
            return
        }
        #expect(note.severity == .note)
        #expect(note.ruleId == "unreachable.index.age")
        #expect(note.message.contains("1284") || note.message.contains("1,284"))
    }

    /// A store built through the legacy asserted initializer carries no measurement. It must
    /// keep working rather than barrier every caller that has not adopted the new path.
    @Test("An asserted store without a measurement still runs")
    func assertedStoreStillRuns() {
        let outcome = UnreachableCodeAuditor.indexProvenance(
            located: StoreLocator.LocatedStore(url: store, isStale: false)
        )
        #expect(outcome.shouldRun)
        #expect(outcome.diagnostics.isEmpty)
    }
}
