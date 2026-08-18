import Foundation
import Testing
import QualityGateCore
@testable import BoundedIOAuditor

/// The kernel is a property of the repository, not of this one.
///
/// `bounded-io` permitted unbounded primitives in exactly one hardcoded path —
/// `Sources/QualityGateCore/ProcessRunner.swift` — which names *this* package's own type. A
/// foreign repository does not depend on `QualityGateCore` and has no such module, so every
/// one of its spawn sites was outside the kernel by construction, the suggested fix named a
/// symbol it could not import, and **writing the correct fix did not clear the rule**: a
/// project that built a real bounded kernel at its own path got it flagged like any other
/// file. The only reachable green state was an `// Unbounded:` marker on the kernel's own
/// `Process()`, which inverts what that marker means.
///
/// See `project/plans/proposals/BoundedIOKernelPath.md`.
@Suite("bounded-io: the kernel is configurable")
struct KernelPathConfigTests {

    private static let spawn = """
    import Foundation
    let process = Process()
    """

    @Test("A configured kernel path is exempt")
    func configuredKernelIsExempt() {
        let scan = BoundedIOAuditor.scan(
            source: Self.spawn,
            fileName: "/checkout/Sources/Foo/MyRunner.swift",
            kernelPath: "Sources/Foo/MyRunner.swift")
        #expect(scan.diagnostics.isEmpty,
                "the declared kernel was still flagged: \(scan.diagnostics.map { $0.ruleId ?? "?" })")
    }

    /// Guards the resident repository: the default must stay exactly what it was.
    @Test("With no configuration, this package's own kernel is still exempt")
    func defaultKernelUnchanged() {
        let scan = BoundedIOAuditor.scan(
            source: Self.spawn,
            fileName: "/checkout/Sources/QualityGateCore/ProcessRunner.swift",
            kernelPath: nil)
        #expect(scan.diagnostics.isEmpty)
    }

    @Test("With no configuration, another file is still flagged")
    func defaultNonKernelStillFlagged() {
        let scan = BoundedIOAuditor.scan(
            source: Self.spawn,
            fileName: "/checkout/Sources/Foo/MyRunner.swift",
            kernelPath: nil)
        #expect(scan.diagnostics.contains { ($0.ruleId ?? "").contains("bounded-io") })
    }

    /// Declaring a kernel must not weaken the rule anywhere else.
    @Test("Configuring a kernel does not exempt other files")
    func configuredKernelDoesNotWeakenElsewhere() {
        let scan = BoundedIOAuditor.scan(
            source: Self.spawn,
            fileName: "/checkout/Sources/Bar/Other.swift",
            kernelPath: "Sources/Foo/MyRunner.swift")
        #expect(scan.diagnostics.contains { ($0.ruleId ?? "").contains("bounded-io") })
    }

    /// A diagnostic naming a symbol the reader cannot import is worse than no diagnostic.
    @Test("Diagnostics name the configured kernel, not ProcessRunner")
    func diagnosticsNameConfiguredKernel() {
        let scan = BoundedIOAuditor.scan(
            source: Self.spawn,
            fileName: "/checkout/Sources/Bar/Other.swift",
            kernelPath: "Sources/Foo/MyRunner.swift")
        let text = scan.diagnostics.map { $0.message + " " + ($0.suggestedFix ?? "") }.joined()
        #expect(text.contains("MyRunner"), "expected the configured kernel to be named; got: \(text)")
        #expect(!text.contains("ProcessRunner"),
                "the diagnostic named a symbol this repository cannot import: \(text)")
    }

    @Test("The coverage note names the configured kernel")
    func coverageNamesConfiguredKernel() {
        let scan = BoundedIOAuditor.scan(
            source: Self.spawn,
            fileName: "/checkout/Sources/Bar/Other.swift",
            kernelPath: "Sources/Foo/MyRunner.swift")
        #expect(scan.coverageLine.contains("MyRunner"),
                "coverage note still names another package's kernel: \(scan.coverageLine)")
    }

    /// A reasoned acknowledgement outside a configured kernel still aggregates, as now.
    @Test("Acknowledgements still aggregate when a kernel is configured")
    func acknowledgementsStillAggregate() {
        let source = """
        import Foundation
        // Unbounded: an interactive editor must inherit the tty and outlive any deadline.
        let process = Process()
        """
        let scan = BoundedIOAuditor.scan(
            source: source,
            fileName: "/checkout/Sources/Bar/Editor.swift",
            kernelPath: "Sources/Foo/MyRunner.swift")
        #expect(scan.acknowledged == 1)
    }
}
