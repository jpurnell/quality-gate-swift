import Testing
@testable import QualityGateCore

/// Properties for the overlay path guard.
///
/// `sanitized` collapses an arbitrary identity slug into one safe path component so
/// that every overlay stays inside `overlays/`. The identity comes from resolution
/// this type does not control, which is precisely the shape that wants a property
/// rather than a handful of chosen inputs: the interesting cases are the ones nobody
/// thought to write down.
@Suite("OverlayStore path containment")
struct OverlayStorePropertyTests {

    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    /// Fragments chosen to include every traversal shape, plus the ones that only
    /// become dangerous after another substitution has run.
    private static let fragments = [
        "..", "/", "\\", ".", "a", "Z9", "_", " ", "", "...", "../", "..\\",
        "%2e%2e", "\u{0}", "café", "..%2f", "....//", "//", "\\\\",
    ]

    private func identity(_ rng: inout Seeded) -> String {
        (0..<Int(rng.next() % 12))
            .map { _ in Self.fragments[Int(rng.next() % UInt64(Self.fragments.count))] }
            .joined()
    }

    /// **The containment property.** No separator, no traversal, never empty — for
    /// any identity at all.
    @Test("A sanitized identity is always one safe path component")
    func containment() {
        var rng = Seeded(seed: 20_260_815)
        for _ in 0..<2_000 {
            let raw = identity(&rng)
            let safe = OverlayStore.sanitized(raw)
            #expect(!safe.contains("/"), "separator survived: \(raw.debugDescription) -> \(safe)")
            #expect(!safe.contains("\\"), "separator survived: \(raw.debugDescription) -> \(safe)")
            #expect(!safe.contains(".."), "traversal survived: \(raw.debugDescription) -> \(safe)")
            #expect(!safe.isEmpty, "empty component from: \(raw.debugDescription)")
        }
    }

    /// **Idempotent.** Sanitising an already-safe component changes nothing, so a
    /// value that round-trips through storage cannot drift.
    @Test("Sanitising is idempotent")
    func idempotent() {
        var rng = Seeded(seed: 4_242)
        for _ in 0..<1_000 {
            let once = OverlayStore.sanitized(identity(&rng))
            #expect(OverlayStore.sanitized(once) == once, "drifted: \(once)")
        }
    }

    /// **Total.** Every input yields a component, including the empty string and
    /// input that sanitises away to nothing.
    @Test("Every input yields a usable component")
    func total() {
        for raw in ["", " ", ".", "..", "...", "./", "../..", "   . . .   ", "/"] {
            let safe = OverlayStore.sanitized(raw)
            #expect(!safe.isEmpty, "input: \(raw.debugDescription)")
            #expect(!safe.contains(".."))
        }
    }
}
