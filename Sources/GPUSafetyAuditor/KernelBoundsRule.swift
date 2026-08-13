import Foundation
import QualityGateCore

/// Rule 1 — a kernel that indexes by thread id with no bound it *could* be
/// checked against.
///
/// ## What this decides, and what it refuses to
///
/// Metal dispatches whole threadgroups, so a grid is rounded up to a multiple of
/// the threadgroup width and the surplus threads run the body. At
/// `populationSize = 1200` with a width of 256 that is 1280 threads for 1200
/// elements; eighty of them read and write past every buffer. The GPU reports
/// success and returns different numbers, which is why the symptom is an optimiser
/// that reproduces *sometimes* rather than a crash.
///
/// The rule reports that **the thread id is never compared against any scalar the
/// kernel was given**. Not "there is no early return", and not "no scalar exists".
///
/// The design proposal specified the weaker test — *no scalar parameter exists* —
/// and its own Golden Path refutes it. `initializeRNG` was quoted as having "no
/// scalar count parameter", but its signature is
/// `(device RNGState*, constant ulong& baseSeed, uint tid)`: `baseSeed` **is** a
/// scalar by shape. A seed is not a count, and nothing in a signature distinguishes
/// them. Under the proposed rule the motivating defect goes unreported.
///
/// Requiring the bound to be *used* fixes that and is strictly stronger. The
/// proposal recorded that of eleven unguarded kernels only six had no count
/// parameter, and that "the other five had one and simply did not use it" would be
/// missed. This rule catches those five.
///
/// It still does **not** report absence of an early return, and that restraint is
/// the expensive lesson:
///
/// - A tiled kernel bounds its writes and deliberately has no early return, because
///   out-of-range threads must keep reaching `threadgroup_barrier` or the threads
///   that do reach it wait forever. The naive version was written first, flagged
///   exactly such a kernel, and its suggested repair would have turned correct code
///   into a hang. Comparing anywhere in the body — in a ternary, at the write, in a
///   loop condition — counts as bounded, because all of those are real guards.
///
/// What remains undecidable, and is not claimed: whether a *present* comparison uses
/// the *right* bound. `tid >= numOps` type-checks exactly as well as
/// `tid >= iterations`.
public enum KernelBoundsRule {

    /// The rule's identifier.
    public static let id = "gpu.unbounded-thread-id"

    /// Diagnoses one kernel.
    ///
    /// - Parameter kernel: The kernel to examine.
    /// - Returns: One diagnostic when no bound is available, otherwise none.
    public static func diagnose(_ kernel: MetalKernel) -> [Diagnostic] {
        guard let threadID = kernel.threadPositionParameter else { return [] }
        guard kernel.indexesBufferWithThreadID else { return [] }
        guard !isBounded(kernel, threadID: threadID) else { return [] }

        let buffers = kernel.bufferParameters.sorted().joined(separator: ", ")
        let remedy = kernel.scalarParameters.isEmpty
            ? "It takes no scalar parameter it could be bounded against — pass the element count and guard on it."
            : "It is given \(kernel.scalarParameters.sorted().joined(separator: ", ")), but never compares `\(threadID)` against any of them."
        return [Diagnostic(
            severity: .error,
            message: """
                Kernel `\(kernel.name)` indexes \(buffers) by `\(threadID)` with no bound. \
                \(remedy) Metal rounds a dispatch up to whole threadgroups, so surplus threads \
                run this body and read or write past every buffer — silently, and only at sizes \
                that are not a multiple of the threadgroup width.
                """,
            filePath: kernel.source.path,
            lineNumber: kernel.source.line ?? kernel.declarationLine,
            ruleId: id)]
    }

    /// Whether the body compares the thread id against one of the kernel's scalars.
    ///
    /// Co-occurrence within a single statement, alongside a relational operator or a
    /// clamping call. Deliberately permissive about *where* the comparison sits: a
    /// ternary, a loop condition and an `if` around the write are all real guards,
    /// and demanding an early return is what turns a correct tiled kernel into a
    /// deadlock.
    static func isBounded(_ kernel: MetalKernel, threadID: String) -> Bool {
        guard !kernel.scalarParameters.isEmpty else { return false }
        let statements = kernel.body.split(whereSeparator: { $0 == ";" || $0.isNewline })
        for statement in statements {
            guard statement.containsIdentifier(threadID) else { continue }
            let hasRelation = ["<", ">", "<=", ">=", "==", "!="].contains { statement.contains($0) }
            let hasClamp = statement.contains("min(") || statement.contains("clamp(")
            guard hasRelation || hasClamp else { continue }
            for scalar in kernel.scalarParameters where statement.containsIdentifier(scalar) {
                return true
            }
        }
        return false
    }
}
