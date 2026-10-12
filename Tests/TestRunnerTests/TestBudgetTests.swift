import Foundation
import Testing
@testable import QualityGateCore

/// How long one `swift test` is allowed to take.
///
/// `ProcessRunner`'s default is 600 seconds — correct for `git rev-parse`, which is what most
/// of its callers run, and wrong for a whole test suite. `runSwiftTest` inherited that default,
/// so the budget was a constant nobody chose: it fit until the suite grew past it, and then
/// every commit and every push failed at exactly 600.0s with no finding to show for it.
///
/// Derived from what the suite last took, so it tracks the suite rather than being re-guessed
/// each time it is outgrown.
@Suite("Test budget")
struct TestBudgetTests {

    @Test("With no history, a first run gets the generous budget rather than the floor")
    func firstRunIsGenerous() {
        let budget = CheckerBudget.seconds(lastSuccess: nil)
        #expect(budget == 3_600)
    }

    /// A cold build and a full suite legitimately take longer than a warm re-run, and the
    /// first run after a `clean` is exactly when a too-small budget is most likely to fire.
    @Test("A zero or negative record is treated as no history, not as an instant suite")
    func nonsenseHistoryIsIgnored() {
        #expect(CheckerBudget.seconds(lastSuccess: 0) == 3_600)
        #expect(CheckerBudget.seconds(lastSuccess: -5) == 3_600)
    }

    @Test("A fast suite still gets the floor, so normal variance cannot fail a run")
    func floorApplies() {
        // 60s × 3 is 180s, well under the floor: a suite that usually takes a minute must not
        // be killed because one run was slow to start.
        #expect(CheckerBudget.seconds(lastSuccess: 60) == 900)
    }

    @Test("A slow suite gets headroom proportional to what it actually takes")
    func headroomScales() {
        // 400s × 3 = 1200s. The suite that prompted this took ~200s and then grew past 600
        // when roughly a thousand tests landed; three times the observed duration absorbs
        // that kind of growth without another constant to outgrow.
        #expect(CheckerBudget.seconds(lastSuccess: 400) == 1_200)
    }

    @Test("The budget rises with the recorded duration, monotonically")
    func monotonic() {
        let budgets = [100.0, 300.0, 500.0, 900.0].map { CheckerBudget.seconds(lastSuccess: $0) }
        #expect(budgets == budgets.sorted())
        #expect(budgets.last == 2_700)
    }
}
