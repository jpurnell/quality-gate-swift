import Testing
@testable import GPUSafetyAuditor

@Suite("MetalKernelParser")
struct MetalKernelParserTests {

    /// The Golden Path assertion from the proposal: `initializeRNG` as it stood in
    /// BusinessMath before the guards were added. Signature carries a thread id and
    /// a seed, and no scalar count — so there is no bound it *could* be checked
    /// against.
    static let initializeRNG = """
        kernel void initializeRNG(device RNGState *states [[buffer(0)]],
                                  constant ulong& baseSeed [[buffer(1)]],
                                  uint tid [[thread_position_in_grid]]) {
            states[tid].seed = baseSeed + tid;
        }
        """

    /// The regression that matters most. This kernel bounds its own writes, and
    /// deliberately has no early return: out-of-range threads must keep reaching
    /// `threadgroup_barrier` or the threads that do reach it wait forever.
    static let matrixMultiplyTiled = """
        kernel void matrixMultiplyTiled(device const float *a [[buffer(0)]],
                                        device const float *b [[buffer(1)]],
                                        device float *c [[buffer(2)]],
                                        constant uint& n [[buffer(3)]],
                                        uint2 gid [[thread_position_in_grid]],
                                        uint2 lid [[thread_position_in_threadgroup]]) {
            threadgroup float tileA[16][16];
            float sum = 0.0;
            for (uint t = 0; t < n; t += 16) {
                tileA[lid.y][lid.x] = (gid.y < n) ? a[gid.y * n + t + lid.x] : 0.0;
                threadgroup_barrier(mem_flags::mem_threadgroup);
                sum += tileA[lid.y][lid.x];
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }
            if (gid.x < n && gid.y < n) {
                c[gid.y * n + gid.x] = sum;
            }
        }
        """

    @Test("Recovers the entry point name")
    func recoversName() {
        let kernels = MetalKernelParser.kernels(
            in: Self.initializeRNG, source: .metalFile(path: "X.metal", excludedFromTarget: false))
        #expect(kernels.count == 1)
        #expect(kernels.first?.name == "initializeRNG")
    }

    @Test("Recovers the thread-position parameter")
    func recoversThreadPosition() {
        let kernels = MetalKernelParser.kernels(
            in: Self.initializeRNG, source: .metalFile(path: "X.metal", excludedFromTarget: false))
        #expect(kernels.first?.threadPositionParameter == "tid")
    }

    /// `baseSeed` is `constant ulong&` and so is a scalar by shape — but a seed is
    /// not a count. The parser reports candidates; deciding a seed cannot bound a
    /// grid is not something the signature can tell us, which is exactly why Rule 1
    /// reports only the *absence* of any candidate.
    @Test("Distinguishes scalar candidates from buffers")
    func separatesScalarsFromBuffers() {
        let kernels = MetalKernelParser.kernels(
            in: Self.initializeRNG, source: .metalFile(path: "X.metal", excludedFromTarget: false))
        #expect(kernels.first?.scalarParameters == ["baseSeed"])
        #expect(kernels.first?.bufferParameters == ["states"])
    }

    @Test("Recovers every parameter of a tiled kernel without tripping on nested brackets")
    func parsesTiledSignature() {
        let kernels = MetalKernelParser.kernels(
            in: Self.matrixMultiplyTiled,
            source: .metalFile(path: "M.metal", excludedFromTarget: false))
        #expect(kernels.count == 1)
        #expect(kernels.first?.name == "matrixMultiplyTiled")
        #expect(kernels.first?.threadPositionParameter == "gid")
        #expect(kernels.first?.scalarParameters == ["n"])
        #expect(kernels.first?.bufferParameters == ["a", "b", "c"])
    }

    @Test("Body is captured brace to matching brace")
    func capturesBody() {
        let kernels = MetalKernelParser.kernels(
            in: Self.matrixMultiplyTiled,
            source: .metalFile(path: "M.metal", excludedFromTarget: false))
        let body = kernels.first?.body ?? ""
        #expect(body.contains("threadgroup_barrier"))
        #expect(body.contains("c[gid.y * n + gid.x] = sum;"))
        #expect(!body.contains("kernel void"))
    }

    @Test("Finds multiple kernels in one source, in order")
    func findsMultipleKernels() {
        let text = Self.initializeRNG + "\n\n" + Self.matrixMultiplyTiled
        let kernels = MetalKernelParser.kernels(
            in: text, source: .metalFile(path: "Both.metal", excludedFromTarget: false))
        #expect(kernels.map(\.name) == ["initializeRNG", "matrixMultiplyTiled"])
    }

    /// A function whose name merely ends in `kernel` is not an entry point.
    @Test("Does not treat a name ending in 'kernel' as an entry point")
    func ignoresSuffixMatch() {
        let text = "float my_kernel(float x) { return x; }"
        let kernels = MetalKernelParser.kernels(
            in: text, source: .metalFile(path: "X.metal", excludedFromTarget: false))
        #expect(kernels.isEmpty)
    }

    @Test("Reports the declaration line")
    func reportsLine() {
        let text = "// header\n\n" + Self.initializeRNG
        let kernels = MetalKernelParser.kernels(
            in: text, source: .metalFile(path: "X.metal", excludedFromTarget: false))
        #expect(kernels.first?.declarationLine == 3)
    }

    // MARK: - Thread-id indexing

    @Test("Detects the thread id indexing a device buffer")
    func detectsIndexing() {
        let kernels = MetalKernelParser.kernels(
            in: Self.initializeRNG, source: .metalFile(path: "X.metal", excludedFromTarget: false))
        #expect(kernels.first?.indexesBufferWithThreadID == true)
    }

    /// `grid` contains the letters of `id`. A substring match would report this
    /// kernel as indexing by thread id when it does not.
    @Test("Whole-word matching: 'id' does not match inside 'grid'")
    func wholeWordOnly() {
        let text = """
            kernel void useGridOnly(device float *out [[buffer(0)]],
                                    constant uint& gridSize [[buffer(1)]],
                                    uint id [[thread_position_in_grid]]) {
                out[gridSize] = 1.0;
            }
            """
        let kernels = MetalKernelParser.kernels(
            in: text, source: .metalFile(path: "X.metal", excludedFromTarget: false))
        #expect(kernels.first?.indexesBufferWithThreadID == false)
    }
}
