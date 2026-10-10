import Foundation

// MARK: - Constants

/// A number folded from literals, kept under both readings a literal has.
///
/// `7 / 2` is `3` where the literals are integers and `3.5` where they are
/// floating-point, and syntax does not always say which. Both are carried, and
/// the constant counts as nonzero only when both readings are: `1 / 2` is a
/// zero divisor in exactly the place a reader would not look for one.
struct DivisorConstant: Sendable, Equatable {
    /// The value under integer arithmetic. Nil once a floating-point literal or
    /// a conversion to a floating-point type has been involved.
    var integer: Int?
    /// The value under floating-point arithmetic.
    var real: Double
    /// The width of the integer type, where one was written: `UInt64(1)`,
    /// `: UInt8`. Unwritten is 32 — `Int` is 32 bits on arm64_32, which every
    /// Apple Watch before Series 9 is, so `1 << 53` is not known to be nonzero.
    var bits: Int = DivisorConstant.unwrittenBits

    /// The width assumed for an integer whose type was not written.
    static let unwrittenBits = 32

    /// An integer literal.
    init(integer value: Int, bits: Int = DivisorConstant.unwrittenBits) {
        self.integer = value
        self.real = Double(value)
        self.bits = bits
    }

    /// A floating-point literal.
    init(real value: Double) {
        self.integer = nil
        self.real = value
    }

    /// True when neither reading is zero.
    var isNonZero: Bool {
        guard real.isFinite, !real.isZero else { return false }
        guard let integer else { return true }
        return integer != 0
    }

    /// The smaller of the two readings.
    var lowest: Double {
        guard let integer else { return real }
        return min(real, Double(integer))
    }

    /// The larger of the two readings.
    var highest: Double {
        guard let integer else { return real }
        return max(real, Double(integer))
    }

    /// The smaller magnitude of the two readings.
    var magnitude: Double {
        guard let integer else { return abs(real) }
        return min(abs(real), abs(Double(integer)))
    }

    /// The constant as a floating-point value. The integer reading wins where
    /// there is one: `Double(1 / 2)` is `0.0`.
    var asFloatingPoint: DivisorConstant {
        guard let integer else { return self }
        return DivisorConstant(real: Double(integer))
    }

    /// The constant as an integer of `bits` bits, or nil when it has no
    /// integer value.
    func asInteger(bits: Int) -> DivisorConstant? {
        if let integer { return DivisorConstant(integer: integer, bits: bits) }
        guard real.isFinite, let truncated = Int(exactly: real.rounded(.towardZero)) else { return nil }
        return DivisorConstant(integer: truncated, bits: bits)
    }

    /// The constant with its sign reversed, or nil when that overflows.
    var negated: DivisorConstant? {
        guard let integer else { return DivisorConstant(real: -real) }
        let (value, overflow) = 0.subtractingReportingOverflow(integer)
        guard !overflow else { return nil }
        var result = DivisorConstant(integer: value, bits: bits)
        result.real = -real
        return result
    }

    /// Applies one arithmetic operator to two constants.
    ///
    /// Nil means "not known", never "zero": an overflow, a division by a zero
    /// constant, or a shift this cannot place inside its type all end here, and
    /// the divisor that contains one stays reported.
    static func combine(_ lhs: DivisorConstant, _ operatorText: String, _ rhs: DivisorConstant) -> DivisorConstant? {
        switch operatorText {
        case "<<": return shifted(lhs, by: rhs, left: true)
        case ">>": return shifted(lhs, by: rhs, left: false)
        case "%": return remainder(lhs, rhs)
        case "+", "-", "*", "/": return arithmetic(lhs, operatorText, rhs)
        default: return nil
        }
    }

    private static func arithmetic(
        _ lhs: DivisorConstant,
        _ operatorText: String,
        _ rhs: DivisorConstant
    ) -> DivisorConstant? {
        guard let real = realResult(lhs.real, operatorText, rhs.real) else { return nil }
        var result = DivisorConstant(real: real)
        result.bits = max(lhs.bits, rhs.bits)
        guard let left = lhs.integer, let right = rhs.integer else { return result }
        guard let integer = integerResult(left, operatorText, right) else { return nil }
        result.integer = integer
        return result
    }

    private static func realResult(_ lhs: Double, _ operatorText: String, _ rhs: Double) -> Double? {
        switch operatorText {
        case "+": return lhs + rhs
        case "-": return lhs - rhs
        case "*": return lhs * rhs
        case "/":
            guard !rhs.isZero else { return nil }
            return lhs / rhs
        default: return nil
        }
    }

    private static func integerResult(_ lhs: Int, _ operatorText: String, _ rhs: Int) -> Int? {
        let outcome: (partialValue: Int, overflow: Bool)
        switch operatorText {
        case "+": outcome = lhs.addingReportingOverflow(rhs)
        case "-": outcome = lhs.subtractingReportingOverflow(rhs)
        case "*": outcome = lhs.multipliedReportingOverflow(by: rhs)
        case "/":
            guard rhs != 0 else { return nil }
            outcome = lhs.dividedReportingOverflow(by: rhs)
        default: return nil
        }
        return outcome.overflow ? nil : outcome.partialValue
    }

    private static func remainder(_ lhs: DivisorConstant, _ rhs: DivisorConstant) -> DivisorConstant? {
        guard let left = lhs.integer, let right = rhs.integer, right != 0 else { return nil }
        let outcome = left.remainderReportingOverflow(dividingBy: right)
        guard !outcome.overflow else { return nil }
        return DivisorConstant(integer: outcome.partialValue, bits: max(lhs.bits, rhs.bits))
    }

    /// `lhs << rhs` or `lhs >> rhs`, for a non-negative value and amount.
    ///
    /// A left shift is kept only when the result stays below the sign bit of
    /// the type's width, so no bit is lost under any reading of the type.
    /// `UInt8(1) << 8` and `1 << 64` are zero; `1 << 53` is zero where `Int` is
    /// 32 bits. None of them is a known-nonzero divisor.
    private static func shifted(_ lhs: DivisorConstant, by rhs: DivisorConstant, left: Bool) -> DivisorConstant? {
        guard let value = lhs.integer, let amount = rhs.integer,
              value >= 0, amount >= 0, amount < 62 else { return nil }
        guard left else {
            return DivisorConstant(integer: value >> amount, bits: lhs.bits)
        }
        let outcome = value.multipliedReportingOverflow(by: 1 << amount)
        let usableBits = min(lhs.bits, 63) - 1
        guard !outcome.overflow, usableBits > 0, outcome.partialValue < (1 << usableBits) else { return nil }
        return DivisorConstant(integer: outcome.partialValue, bits: lhs.bits)
    }
}

// MARK: - Facts

/// What is known about the value of an expression used as a divisor.
///
/// Every case tolerates a NaN: "at least one" means "at least one, or not a
/// number". That is deliberate. A NaN divisor gives a NaN quotient, which is
/// propagation and another rule's subject; this rule asks about zero.
enum DivisorFact: Sendable, Equatable {
    /// A number folded from literals.
    case constant(DivisorConstant)
    /// The value is at least the bound — above it, when `strict`.
    case atLeast(Double, strict: Bool)
    /// The value is not zero; its sign and size are not known.
    case nonZero

    /// Below this a lower bound is not treated as a size: a product of bounds
    /// has to stay above it to count as bounded away from zero, so that the
    /// claim survives a `Float`.
    static let smallestTrustedMagnitude = 1e-30

    /// True when the value cannot be zero.
    var isNonZero: Bool {
        switch self {
        case .constant(let constant): return constant.isNonZero
        case .atLeast(let bound, let strict): return bound > 0 || (strict && bound >= 0)
        case .nonZero: return true
        }
    }

    /// The value's lower bound, where it has one.
    ///
    /// Never a NaN. Literal arithmetic can produce one (`1e308 * 10 - 1e308 * 10`),
    /// and a NaN compares false with everything, so it would pass through
    /// `max` and `min` below as if it were a bound. It is not one.
    var lowerBound: (value: Double, strict: Bool)? {
        switch self {
        case .constant(let constant):
            return constant.lowest.isNaN ? nil : (constant.lowest, false)
        case .atLeast(let bound, let strict):
            return bound.isNaN ? nil : (bound, strict)
        case .nonZero:
            return nil
        }
    }

    /// A lower bound on the value's magnitude. Zero when only its being
    /// nonzero is known.
    private var magnitude: Double {
        switch self {
        case .constant(let constant): return constant.magnitude
        case .atLeast(let bound, _): return max(bound, 0)
        case .nonZero: return 0
        }
    }

    /// True when the value is known not to be negative.
    private var isNonNegative: Bool {
        guard let bound = lowerBound else { return false }
        return bound.value >= 0
    }

    // MARK: Arithmetic

    /// `lhs + rhs`. Two lower bounds add.
    static func sum(_ lhs: DivisorFact, _ rhs: DivisorFact) -> DivisorFact? {
        if case .constant(let left) = lhs, case .constant(let right) = rhs {
            return DivisorConstant.combine(left, "+", right).map(DivisorFact.constant)
        }
        guard let left = lhs.lowerBound, let right = rhs.lowerBound else { return nil }
        return .atLeast(left.value + right.value, strict: left.strict || right.strict)
    }

    /// `lhs - rhs`. A lower bound less a constant is a lower bound. In IEEE
    /// arithmetic `x - k` is zero only when `x == k`, so `x > k` is enough.
    static func difference(_ lhs: DivisorFact, _ rhs: DivisorFact) -> DivisorFact? {
        guard case .constant(let right) = rhs else { return nil }
        if case .constant(let left) = lhs {
            return DivisorConstant.combine(left, "-", right).map(DivisorFact.constant)
        }
        guard let left = lhs.lowerBound else { return nil }
        return .atLeast(left.value - right.highest, strict: left.strict)
    }

    /// `lhs * rhs`.
    ///
    /// A product of nonzero floating-point values can be zero: `1e-200 * 1e-200`
    /// underflows. So a product is nonzero only where that cannot happen — the
    /// sizes are both known and their product is not tiny, or one factor is at
    /// least one in magnitude, which can only make the other larger.
    static func product(_ lhs: DivisorFact, _ rhs: DivisorFact) -> DivisorFact? {
        if case .constant(let left) = lhs, case .constant(let right) = rhs {
            return DivisorConstant.combine(left, "*", right).map(DivisorFact.constant)
        }
        let bothNonNegative = lhs.isNonNegative && rhs.isNonNegative
        let size = lhs.magnitude * rhs.magnitude
        let cannotUnderflow = lhs.magnitude >= 1 || rhs.magnitude >= 1 || size >= smallestTrustedMagnitude
        guard lhs.isNonZero, rhs.isNonZero, cannotUnderflow else {
            return bothNonNegative ? .atLeast(0, strict: false) : nil
        }
        guard bothNonNegative else { return .nonZero }
        return .atLeast(size, strict: size < smallestTrustedMagnitude)
    }

    /// Any other operator: known only between constants.
    static func constantOnly(_ lhs: DivisorFact, _ operatorText: String, _ rhs: DivisorFact) -> DivisorFact? {
        guard case .constant(let left) = lhs, case .constant(let right) = rhs else { return nil }
        return DivisorConstant.combine(left, operatorText, right).map(DivisorFact.constant)
    }

    /// `-self`.
    var negated: DivisorFact? {
        if case .constant(let constant) = self {
            return constant.negated.map(DivisorFact.constant)
        }
        return isNonZero ? .nonZero : nil
    }

    // MARK: Functions

    /// `max(a, b, …)`: at least its largest known lower bound. An argument
    /// nothing is known about cannot lower it.
    static func maximum(_ arguments: [DivisorFact?]) -> DivisorFact? {
        var best: (value: Double, strict: Bool)?
        for bound in arguments.compactMap({ $0?.lowerBound }) {
            guard let current = best else {
                best = bound
                continue
            }
            if bound.value > current.value || (bound.value >= current.value && bound.strict) {
                best = bound
            }
        }
        return best.map { .atLeast($0.value, strict: $0.strict) }
    }

    /// `min(a, b, …)`: at least its smallest lower bound, and only when every
    /// argument has one.
    static func minimum(_ arguments: [DivisorFact?]) -> DivisorFact? {
        var worst: (value: Double, strict: Bool)?
        for argument in arguments {
            guard let bound = argument?.lowerBound, !bound.value.isNaN else { return nil }
            guard let current = worst else {
                worst = bound
                continue
            }
            if bound.value < current.value {
                worst = bound
            } else if bound.value <= current.value {
                worst = (current.value, current.strict && bound.strict)
            }
        }
        return worst.map { .atLeast($0.value, strict: $0.strict) }
    }

    /// `abs(x)`: never negative, and positive when `x` is not zero.
    static func absolute(_ argument: DivisorFact?) -> DivisorFact {
        guard let argument, argument.isNonZero else { return .atLeast(0, strict: false) }
        return .atLeast(argument.isNonNegative ? argument.magnitude : 0, strict: true)
    }

    /// `sqrt(x)`: never negative (or not a number).
    static func squareRoot(_ argument: DivisorFact?) -> DivisorFact {
        guard let bound = argument?.lowerBound, bound.value >= 0 else { return .atLeast(0, strict: false) }
        if case .constant(let constant)? = argument, constant.asFloatingPoint.real >= 0 {
            return .constant(DivisorConstant(real: constant.asFloatingPoint.real.squareRoot()))
        }
        return .atLeast(bound.value.squareRoot(), strict: bound.strict)
    }

    /// `c ? a : b`: whatever is true of both.
    static func either(_ lhs: DivisorFact?, _ rhs: DivisorFact?) -> DivisorFact? {
        guard let lhs, let rhs else { return nil }
        if let joined = minimum([lhs, rhs]), joined.isNonZero { return joined }
        if lhs.isNonZero && rhs.isNonZero { return .nonZero }
        return minimum([lhs, rhs])
    }

    /// The stronger of two facts about one value.
    static func stronger(_ lhs: DivisorFact?, _ rhs: DivisorFact?) -> DivisorFact? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if case .constant = lhs { return lhs }
        if case .constant = rhs { return rhs }
        guard let left = lhs.lowerBound else { return sharpened(rhs, nonZero: true) }
        guard let right = rhs.lowerBound else { return sharpened(lhs, nonZero: true) }
        return maximum([.atLeast(left.value, strict: left.strict), .atLeast(right.value, strict: right.strict)])
    }

    /// `fact`, with the knowledge that the value is not zero folded in:
    /// "at least zero" and "not zero" together are "above zero".
    private static func sharpened(_ fact: DivisorFact, nonZero: Bool) -> DivisorFact {
        guard nonZero, case .atLeast(let bound, let strict) = fact else { return fact }
        if bound < 0 { return .nonZero }
        return .atLeast(bound, strict: strict || bound <= 0)
    }

    // MARK: Conversions

    /// The fact after conversion to a floating-point type.
    ///
    /// A bound is kept: `Float(x)` is read as `x` in another type, which is how
    /// the rule has always read a conversion — see ``FallbackSubjectKey``.
    /// What a narrower type cannot keep is the gap above a bound. `x > 1` does
    /// not make `Float(x) > 1`: `1 + 1e-12` is `1` as a `Float`, and
    /// `Float(x) - 1` is then zero. So "above a positive bound" becomes "at
    /// least" it.
    ///
    /// - Parameter narrowing: The target may hold fewer digits than the source.
    func asFloatingPoint(narrowing: Bool) -> DivisorFact {
        switch self {
        case .constant(let constant):
            return .constant(constant.asFloatingPoint)
        case .atLeast(let bound, let strict):
            return .atLeast(bound, strict: strict && !(narrowing && bound > 0))
        case .nonZero:
            return self
        }
    }

    /// The fact after conversion to an integer type of `bits` bits.
    ///
    /// `Int(0.5)` is zero, so "above zero" does not survive the conversion and
    /// "at least one" does.
    func asInteger(bits: Int) -> DivisorFact? {
        switch self {
        case .constant(let constant):
            return constant.asInteger(bits: bits).map(DivisorFact.constant)
        case .atLeast(let bound, _):
            if bound >= 1 { return .atLeast(bound.rounded(.down), strict: false) }
            return bound >= 0 ? .atLeast(0, strict: false) : nil
        case .nonZero:
            return nil
        }
    }
}
