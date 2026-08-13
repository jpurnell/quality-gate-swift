import Testing
@testable import GPUSafetyAuditor

@Suite("KernelBoundsRule")
struct KernelBoundsRuleTests {

    private func kernels(_ text: String) -> [MetalKernel] {
        MetalKernelParser.kernels(
            in: text, source: .metalFile(path: "Shaders.metal", excludedFromTarget: false))
    }

    /// Golden path. `initializeRNG` as it stood before the guards: a thread id, a
    /// seed, and no count. There is nothing in scope to bound the id against.
    @Test("Fires on a kernel with no scalar parameter at all")
    func firesOnUnbounded() {
        let found = kernels(MetalKernelParserTests.initializeRNG)
        let diagnostics = found.flatMap(KernelBoundsRule.diagnose)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.ruleId == "gpu.unbounded-thread-id")
        #expect(diagnostics.first?.severity == .error)
        #expect(diagnostics.first?.message.contains("initializeRNG") == true)
    }

    /// **The regression that matters most.** A checker that flags this will be
    /// switched off within a week, and its suggested fix — add an early return —
    /// converts a correct kernel into a deadlock, because out-of-range threads must
    /// keep reaching `threadgroup_barrier`.
    @Test("Stays silent on matrixMultiplyTiled")
    func silentOnTiledMatrixMultiply() {
        let found = kernels(MetalKernelParserTests.matrixMultiplyTiled)
        #expect(found.flatMap(KernelBoundsRule.diagnose).isEmpty)
    }

    /// The population the proposal expected to miss. Of eleven unguarded kernels in
    /// the motivating codebase, five *had* a count parameter and simply never used
    /// it; §12 recorded that as an accepted gap. Requiring the bound to be used
    /// rather than merely present closes it.
    @Test("Fires when a count parameter exists but the id is never compared to it")
    func firesWhenBoundUnused() {
        let text = """
            kernel void scaleAll(device float *out [[buffer(0)]],
                                 constant uint& count [[buffer(1)]],
                                 uint id [[thread_position_in_grid]]) {
                out[id] = out[id] * 2.0;
            }
            """
        let diagnostics = kernels(text).flatMap(KernelBoundsRule.diagnose)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains("never compares") == true)
        #expect(diagnostics.first?.message.contains("count") == true)
    }

    /// A guard placed at the write rather than as an early return still bounds the
    /// kernel. Demanding an early return is what deadlocks a tiled kernel.
    @Test("Stays silent when the guard is at the write, not an early return")
    func silentWhenGuardedAtWrite() {
        let text = """
            kernel void guardedAtWrite(device float *out [[buffer(0)]],
                                       constant uint& n [[buffer(1)]],
                                       uint id [[thread_position_in_grid]]) {
                float value = 1.0;
                if (id < n) { out[id] = value; }
            }
            """
        #expect(kernels(text).flatMap(KernelBoundsRule.diagnose).isEmpty)
    }

    /// A guarded kernel has a bound and uses it. Silent.
    @Test("Stays silent when a count parameter exists and is compared")
    func silentWhenBoundAvailable() {
        let text = """
            kernel void addVectors(device const float *a [[buffer(0)]],
                                   device float *out [[buffer(1)]],
                                   constant uint& count [[buffer(2)]],
                                   uint id [[thread_position_in_grid]]) {
                if (id >= count) { return; }
                out[id] = a[id] + 1.0;
            }
            """
        #expect(kernels(text).flatMap(KernelBoundsRule.diagnose).isEmpty)
    }

    /// The rule is about indexing, not about taking a thread id. A kernel that uses
    /// its id only for a barrier decision cannot overrun.
    @Test("Stays silent when the thread id never indexes a buffer")
    func silentWhenIDNeverIndexes() {
        let text = """
            kernel void countOnly(device atomic_uint *total [[buffer(0)]],
                                  uint id [[thread_position_in_grid]]) {
                if (id == 0) { atomic_store_explicit(total, 0, memory_order_relaxed); }
            }
            """
        #expect(kernels(text).flatMap(KernelBoundsRule.diagnose).isEmpty)
    }

    /// No thread id means no per-thread indexing and nothing to bound.
    @Test("Stays silent on a kernel with no thread-position parameter")
    func silentWithoutThreadID() {
        let text = """
            kernel void clearAll(device float *out [[buffer(0)]]) {
                out[0] = 0.0;
            }
            """
        #expect(kernels(text).flatMap(KernelBoundsRule.diagnose).isEmpty)
    }

    /// The message has to name the buffers, or the reader cannot act on it without
    /// re-reading the kernel.
    @Test("Message names the kernel and the buffers at risk")
    func messageIsActionable() {
        let diagnostics = kernels(MetalKernelParserTests.initializeRNG)
            .flatMap(KernelBoundsRule.diagnose)
        let message = diagnostics.first?.message ?? ""
        #expect(message.contains("states"))
        #expect(message.contains("tid"))
    }

    /// Determinism: two runs over the same input produce byte-identical output.
    @Test("Diagnosis is deterministic across runs")
    func deterministic() {
        let text = MetalKernelParserTests.initializeRNG
        let first = kernels(text).flatMap(KernelBoundsRule.diagnose).map(\.message)
        let second = kernels(text).flatMap(KernelBoundsRule.diagnose).map(\.message)
        #expect(first == second)
    }
}
