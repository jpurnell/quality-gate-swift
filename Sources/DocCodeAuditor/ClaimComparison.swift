import Foundation

/// The comparisons a documented figure can be held to.
///
/// Three different claims hide under `==` on floating-point values, and this names them so
/// an assertion says which one it is making. The vocabulary is deliberately the same as the
/// one BusinessMath's own test suite uses across 428 call sites — the question rung 3 asks
/// (is this documented figure bit-exact, IEEE-equal, or within a stated tolerance) is the
/// same question, and it gets the same three answers. No fourth was invented.
///
/// ## Which one applies where
///
/// | Written | Comparison |
/// | --- | --- |
/// | `~99,377`, `≈ 0.0` — approximate, author-marked | ``approximatelyEqual(_:_:tolerance:)``, two units in the last written place |
/// | `100,000` — approximate, author unaware | ``approximatelyEqual(_:_:tolerance:)``, half a unit in the last written place |
/// | Two runs of the same seeded program | ``identical(_:_:)`` |
///
/// ``identical(_:_:)`` is not used for a value claim, and that is the point: reaching for it
/// on a documented figure would fail every correctly-rounded number in the corpus. Naming
/// the three separately is what makes it obvious they are not interchangeable.
public enum ClaimComparison {

    /// Bit-for-bit equality: the same number, down to the encoding.
    ///
    /// Two differences from `==` are deliberate. `identical(-0.0, 0.0)` is `false`, and
    /// `identical(.nan, .nan)` is `true` for two NaNs with the same encoding — which is
    /// exactly what makes this the right comparison for a reproducibility claim, where `==`
    /// would silently pass a stream that had gone NaN.
    public static func identical(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.sign == rhs.sign
            && lhs.exponentBitPattern == rhs.exponentBitPattern
            && lhs.significandBitPattern == rhs.significandBitPattern
    }

    /// IEEE equality, chosen on purpose rather than reached for by habit.
    ///
    /// Exactly as strong as writing `==` inline; the only thing it adds is that the reader
    /// can see the choice was made.
    public static func exactlyEqual(_ lhs: Double, _ rhs: Double) -> Bool { lhs == rhs }

    /// Equality within a stated tolerance.
    ///
    /// The tolerance is a parameter and never a default, because it should come from the
    /// precision of the reference value — here, the number of digits the documentation
    /// chose to write — and not from a habit.
    public static func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Bool {
        abs(lhs - rhs) < tolerance
    }

    /// Whether a measurement satisfies a parsed claim.
    ///
    /// The length of a sequence is part of its claim: `[100, 120, 115]` is not satisfied by
    /// two values that happen to agree, because a documented series that lost an element is
    /// exactly the kind of drift this rung exists to catch.
    ///
    /// - Parameters:
    ///   - expected: The parsed claim.
    ///   - measured: What the program produced.
    /// - Returns: `false` for a claim that is not a value at all — prose cannot be satisfied,
    ///   and reporting it as satisfied would be the worst available answer.
    public static func matches(_ expected: ClaimBody, _ measured: [Double]) -> Bool {
        switch expected {
        case .scalar(let value, let tolerance):
            guard measured.count == 1 else { return false }
            return approximatelyEqual(measured[0], value, tolerance: tolerance)

        case .sequence(let values, let tolerances):
            guard measured.count == values.count else { return false }
            return zip(zip(measured, values), tolerances).allSatisfy { pair, tolerance in
                approximatelyEqual(pair.0, pair.1, tolerance: tolerance)
            }

        case .prose:
            return false
        }
    }

    /// How a claim reads back, for a mismatch report.
    ///
    /// The tolerance is shown because it is the part a reader cannot see in the source. A
    /// finding that says only "expected 100,000, got 100,001" invites the repair of editing
    /// the comment; one that says the check was `± 0.5` says what the documentation actually
    /// promised.
    public static func describe(_ expected: ClaimBody) -> String {
        switch expected {
        case .scalar(let value, let tolerance):
            return "\(value) ± \(tolerance)"
        case .sequence(let values, let tolerances):
            let parts = zip(values, tolerances).map { "\($0) ± \($1)" }
            return "[" + parts.joined(separator: ", ") + "]"
        case .prose:
            return "prose"
        }
    }
}
