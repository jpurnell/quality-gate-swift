import Foundation
import Testing
@testable import BoundedIOAuditor

/// Containment: unbounded primitives live in one audited kernel, and nowhere else.
///
/// ## Why this checker does not try to prove anything
///
/// Deciding whether a given wait is *actually* bounded would require modelling subprocess
/// lifetime, process groups, signal delivery, whether `terminate()` reaches descendants,
/// descriptor inheritance, thread scheduling, cancellation, and whether a timeout handler is even
/// reachable after the wait — let alone whether it interrupts the wait or merely records that it
/// fired. `PluginRunner` fails on the last two alone. No syntactic pass discharges that list, and
/// one that appeared to would be worse than none: it would issue clean verdicts about hangs.
///
/// So the question changes. Not *"is this bounded?"* — undecidable — but *"is this primitive
/// called outside the kernel?"*, which is a grep with an AST behind it. The `unsafe`-block trade:
/// confine what cannot be proven, and audit the confinement by hand.
///
/// ## Why containment is worth more than the checking
///
/// The deadline fix that started this landed on **one of nine sites**, because there was no
/// kernel for a correct fix to propagate from. Containment does not make the kernel correct — it
/// makes it the only place that has to be, and small enough to carry a regression corpus.
@Suite("bounded-io — unbounded primitives stay in the kernel")
struct BoundedIOTests {

    // MARK: - The rule

    @Test("readDataToEndOfFile outside the kernel is reported")
    func unboundedReadOutsideKernelIsReported() throws {
        let source = """
        func run(_ pipe: Pipe) -> Data {
            return pipe.fileHandleForReading.readDataToEndOfFile()
        }
        """
        let found = BoundedIOAuditor.scan(source: source, fileName: "/p/Sources/Elsewhere/Runner.swift").diagnostics
        #expect(found.count == 1)
        #expect(found.first?.ruleId == "bounded-io.outside-kernel")
    }

    /// The same call inside the kernel is not a finding — not because it is proven bounded, but
    /// because that file is the audited place. Its correctness is carried by
    /// `ProcessRunnerDeadlineTests`, not by this checker.
    @Test("the same call inside the kernel is not reported")
    func kernelIsExempt() throws {
        let source = """
        func run(_ pipe: Pipe) -> Data {
            return pipe.fileHandleForReading.readDataToEndOfFile()
        }
        """
        let found = BoundedIOAuditor.scan(
            source: source,
            fileName: "/p/Sources/QualityGateCore/ProcessRunner.swift").diagnostics
        #expect(found.isEmpty, "the kernel is where these primitives are supposed to live")
    }

    @Test("waitUntilExit outside the kernel is reported")
    func waitUntilExitIsReported() throws {
        let source = """
        func run(_ process: Process) {
            process.waitUntilExit()
        }
        """
        let found = BoundedIOAuditor.scan(source: source, fileName: "/p/Sources/X/X.swift").diagnostics
        #expect(found.count == 1)
    }

    /// Absorbed from `security.command-injection`, whose mechanism was `callee == "Process"` — a
    /// containment check wearing an injection rule's name. It was disabled in config by reasoning
    /// that was correct about injection and blind to the second job it was doing, which is how
    /// nine unbounded sites stayed invisible for months.
    @Test("constructing a Process outside the kernel is reported")
    func processConstructionIsReported() throws {
        let source = """
        func spawn() {
            let p = Process()
            p.launchPath = "/bin/ls"
        }
        """
        let found = BoundedIOAuditor.scan(source: source, fileName: "/p/Sources/X/X.swift").diagnostics
        #expect(found.contains { $0.ruleId == "bounded-io.process-construction" })
    }

    // MARK: - The escape hatch

    /// Some call sites genuinely cannot route through the kernel — a sandboxed SPM plugin cannot
    /// import package libraries at all. The acknowledgement records a decision rather than hiding
    /// one: counted into the coverage note, in the shape `TrapPolicy` already uses.
    ///
    /// Emitting a per-site warning was the first design and it was wrong. This project's rule is
    /// that zero warnings means zero, so eighteen deliberate documented decisions would have kept
    /// the gate permanently red, leaving only two ways out: delete the rule, or learn to ignore
    /// the colour. Both are worse than counting.
    @Test("an acknowledged site is counted, not reported as a defect")
    func acknowledgementDowngrades() throws {
        let source = """
        func run(_ pipe: Pipe) -> Data {
            // Unbounded: sandboxed plugin cannot import ProcessRunner; single pipe drained before wait.
            return pipe.fileHandleForReading.readDataToEndOfFile()
        }
        """
        let scan = BoundedIOAuditor.scan(source: source, fileName: "/p/Plugins/P/P.swift")
        #expect(scan.diagnostics.isEmpty, "a reasoned decision is not an unfixed defect")
        #expect(scan.acknowledged == 1, "but it is still counted, and the count is printed")
    }

    /// A bare marker with no argument is not an acknowledgement. If writing the reason truthfully
    /// is impossible, that is the signal — `PluginRunner`'s watchdog could not have been honestly
    /// described as bounding the read.
    @Test("an empty acknowledgement does not count")
    func emptyAcknowledgementRejected() throws {
        let source = """
        func run(_ pipe: Pipe) -> Data {
            // Unbounded:
            return pipe.fileHandleForReading.readDataToEndOfFile()
        }
        """
        let found = BoundedIOAuditor.scan(source: source, fileName: "/p/Sources/X/X.swift").diagnostics
        #expect(found.first?.severity == .error, "a marker without a reason is not a decision")
    }

    // MARK: - Scope

    @Test("a coverage note names the kernel and the primitive count")
    func coverageNoteAlwaysEmitted() throws {
        let scan = BoundedIOAuditor.scan(source: "func f() {}", fileName: "/p/Sources/X/X.swift")
        #expect(scan.diagnostics.isEmpty)
        #expect(scan.coverageLine.contains("kernel"))
    }
}
