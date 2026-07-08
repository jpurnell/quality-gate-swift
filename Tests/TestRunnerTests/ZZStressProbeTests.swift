import Foundation
import Testing

@Suite("ZZ stress probe (throwaway)")
struct ZZStressProbeTests {
    // TIMING: throwaway probe for stress-loop end-to-end verification
    @Test func stressProbeDeterministic() {
        #expect(1 + 1 == 2)
    }
}
