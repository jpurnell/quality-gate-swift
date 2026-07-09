import Testing
@testable import AccessibilityCore

@Suite("AccessibilityPrinciple")
struct AccessibilityPrincipleTests {

    @Test("Every principle cites a non-empty Apple HIG anchor")
    func higAnchorsGrounded() {
        // The standard-holding invariant: a principle cannot exist without naming its
        // Apple HIG basis. Enumerated explicitly (not via allCases) so each is asserted.
        let principles: [AccessibilityPrinciple] = [.textAlternative, .scalableText, .respectMotionPref, .respectVisualPrefs, .operableAltInput, .notColorAlone, .keyboardConsistency, .sufficientTarget]
        for principle in principles {
            #expect(!principle.higAnchor.isEmpty)
            #expect(principle.higAnchor.contains("Apple HIG"))
        }
    }
}
