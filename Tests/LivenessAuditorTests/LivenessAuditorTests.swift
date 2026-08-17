import Foundation
import Testing
@testable import LivenessAuditor

/// Tier A: a blocking primitive whose API offers a bounded overload, called without it.
///
/// This tier makes no claim about whether the wait is *actually* bounded — that question is
/// undecidable in general and the proposal rejects attempting it. It claims something narrower
/// and fully decidable: **the vendor offered a deadline and this call site declined it.** The
/// overload set is the specification, so there is no judgement call about intent.
///
/// Found by asking what the hazard is rather than what the subsystem is. `process-safety` could
/// not have found these — there is no subprocess anywhere near them.
@Suite("Liveness — a bounded overload was declined")
struct LivenessAuditorTests {

    // MARK: - The two real sites

    /// `IJSDashboardCLI/ReviewStore.swift:137` and `DashboardApp.swift:447`, reduced.
    ///
    /// The async-to-sync bridge: a `Task` signals, a synchronous event loop waits. If the task
    /// never completes — because the work it awaits is itself unbounded — the TUI is frozen with
    /// no deadline and no diagnostic. `DashboardApp`'s bridge awaits a corpus write, which
    /// reaches git through one of the nine unbounded reads, so these two hazards compose into a
    /// single hang path.
    @Test("a bare semaphore.wait() is reported")
    func bareSemaphoreWaitIsReported() throws {
        let source = """
        func bridge(_ body: @escaping @Sendable () async -> String) -> String {
            let semaphore = DispatchSemaphore(value: 0)
            Task { _ = await body(); semaphore.signal() }
            semaphore.wait()
            return ""
        }
        """
        let found = LivenessAuditor.scan(source: source, fileName: "Bridge.swift").diagnostics
        #expect(found.count == 1)
        #expect(found.first?.ruleId == "liveness.unbounded-wait")
        #expect(found.first?.lineNumber == 4)
    }

    /// The same call with the deadline taken. This is the whole point of the tier: the repair is
    /// local, obvious, and offered by the API itself.
    @Test("wait(timeout:) is not reported")
    func boundedSemaphoreWaitIsClean() throws {
        let source = """
        func bridge() {
            let semaphore = DispatchSemaphore(value: 0)
            _ = semaphore.wait(timeout: .now() + 5)
        }
        """
        #expect(LivenessAuditor.scan(source: source, fileName: "Bridge.swift").diagnostics.isEmpty)
    }

    // MARK: - The rest of the table

    @Test("DispatchGroup.wait() without a timeout is reported")
    func bareGroupWaitIsReported() throws {
        let source = """
        func drain(_ readers: DispatchGroup) {
            readers.wait()
        }
        """
        let found = LivenessAuditor.scan(source: source, fileName: "Drain.swift").diagnostics
        #expect(found.count == 1)
        #expect(found.first?.ruleId == "liveness.unbounded-wait")
    }

    /// `ProcessRunner:157` — the deadline added today. A checker that reported this would be
    /// telling us to undo the fix, so this is a regression guard on the rule, not just a case.
    @Test("the ProcessRunner deadline shape is not reported")
    func processRunnerDeadlineIsClean() throws {
        let source = """
        func run(timeout: TimeInterval) {
            let readers = DispatchGroup()
            if readers.wait(timeout: .now() + timeout) == .timedOut { }
        }
        """
        #expect(LivenessAuditor.scan(source: source, fileName: "ProcessRunner.swift").diagnostics.isEmpty)
    }

    @Test("NSCondition.wait() is reported")
    func bareConditionWaitIsReported() throws {
        let source = """
        func f(_ c: NSCondition) {
            c.wait()
        }
        """
        let found = LivenessAuditor.scan(source: source, fileName: "F.swift").diagnostics
        #expect(found.count == 1)
        #expect(found.first?.ruleId == "liveness.unbounded-wait")
    }

    @Test("NSCondition.wait(until:) is not reported")
    func boundedConditionWaitIsClean() throws {
        let source = """
        func f(_ c: NSCondition) {
            _ = c.wait(until: Date().addingTimeInterval(5))
        }
        """
        #expect(LivenessAuditor.scan(source: source, fileName: "F.swift").diagnostics.isEmpty)
    }

    /// **NSLock is deliberately outside the table**, decided by measuring before building.
    ///
    /// `NSLock` does offer `lock(before:)`, so by the tier's stated principle it qualifies. It is
    /// excluded anyway: the four `lock()` sites in this repository are all the conventional
    /// `lock(); defer { unlock() }` critical section, two of them in `ProcessRunner.OutputBox`
    /// written the same day as this rule. Reporting them would be a false positive on the most
    /// ordinary pattern in Swift and would break Tier A's only claim on first contact.
    ///
    /// The line is principled rather than expedient: `semaphore.wait()` waits for an **event that
    /// may never occur** — a `Task` that never completes. `lock()` waits for **mutual exclusion**,
    /// bounded by a critical section in this same program. Lock-ordering deadlock is a real
    /// hazard and needs lock-order analysis; it must not be smuggled into a rule that cannot
    /// perform it.
    @Test("NSLock.lock() is not reported — mutual exclusion is a different hazard")
    func nsLockIsOutOfScope() throws {
        let source = """
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }
        """
        #expect(LivenessAuditor.scan(source: source, fileName: "OutputBox.swift").diagnostics.isEmpty)
    }

    // MARK: - Not-a-wait

    /// `wait` is a common method name. The rule keys on the primitive's type, so an unrelated
    /// `wait()` must not be swept in — the tier's zero-false-positive claim depends on this.
    @Test("an unrelated wait() on some other type is not reported")
    func unrelatedWaitIsClean() throws {
        let source = """
        struct Queue { func wait() {} }
        func f(_ q: Queue) { q.wait() }
        """
        #expect(LivenessAuditor.scan(source: source, fileName: "Q.swift").diagnostics.isEmpty)
    }

    // MARK: - Scope honesty

    /// The auditor's silence has been over-read once already: `process-safety` passing was taken
    /// to mean subprocesses could not hang, when it meant nobody had written one syntactic shape.
    /// A pass here states the size of the claim.
    @Test("a coverage note is emitted even when nothing is found")
    func coverageNoteAlwaysEmitted() throws {
        let scan = LivenessAuditor.scan(source: "func f() {}", fileName: "F.swift")
        #expect(scan.diagnostics.isEmpty)
        #expect(scan.coverageLine.contains("examined"))
    }
}
