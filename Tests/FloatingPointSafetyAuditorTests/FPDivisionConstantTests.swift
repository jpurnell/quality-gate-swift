import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// A named constant is the literal it names. Fixtures are the survey sites of 2026-10-09,
// reduced: BusinessMath (LinearityValidation, HestonProcess, Period, PeriodType,
// SimulatedAnnealing, JumpDiffusion), BusinessMath-UI (MonteCarloPath3DView,
// DistributionSurface3DView, Spatial3DView, SpatialAudioManager), BusinessMathPro
// (DerivativesTradingTutorial), sicp-swift-companion (Section_3_1, Section_3_5_5),
// HRVKit (AudioFeedbackEngine), IconquerApp (Projection), BioFeedbackKit (SyntheticRRSource).

private let divisionRule = "fp-division-unguarded"

/// The 1-based lines of every unguarded-division finding in `source`, in order.
private func divisionLines(_ source: String) -> [Int] {
    FloatingPointRules.audit(
        source: source,
        fileName: "Sources/Example/test.swift",
        options: .sources(checkDivisionGuards: true)
    ).diagnostics.filter { $0.ruleId == divisionRule }.compactMap(\.lineNumber)
}

@Suite("fp-division-unguarded: a named constant is the literal it names")
struct FPDivisionConstantTests {

    // MARK: - Local let

    @Test("A local let bound to a nonzero literal is a nonzero divisor")
    func clearsLocalLiteral() {
        let code = """
        func slope(_ f: (Double) -> Double, at x: Double) -> Double {
            let h = 1e-8
            return (f(x + h) - f(x)) / h
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A local let bound to zero still fires")
    func flagsLocalZero() {
        let code = """
        func slope(_ f: (Double) -> Double, at x: Double) -> Double {
            let h = 0.0
            return (f(x + h) - f(x)) / h
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A var bound to a nonzero literal still fires: it can be reassigned")
    func flagsLocalVar() {
        let code = """
        func slope(_ f: (Double) -> Double, at x: Double) -> Double {
            var h = 1e-8
            h = 0
            return (f(x + h) - f(x)) / h
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A local let bound to another value still fires")
    func flagsLocalAliasOfParameter() {
        let code = """
        func ratio(x: Double, y: Double) -> Double {
            let d = y
            return x / d
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A conversion of a local integer constant is a nonzero divisor")
    func clearsConversionOfLocalInteger() {
        let code = """
        func integrate() -> Double {
            let numSteps = 2000
            let upperLimit = 500.0
            let dphi = upperLimit / Double(numSteps)
            return dphi
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A conversion of a local integer zero still fires")
    func flagsConversionOfLocalIntegerZero() {
        let code = """
        func integrate() -> Double {
            let numSteps = 0
            let upperLimit = 500.0
            let dphi = upperLimit / Double(numSteps)
            return dphi
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("An annotated local constant is read through its annotation")
    func clearsAnnotatedLocal() {
        let code = """
        func tone(frame: Int) -> Float {
            let sampleRate: Double = 44100
            return Float(frame) / max(Float(sampleRate), Float.leastNonzeroMagnitude)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("Top-level tutorial constants are read in a script")
    func clearsTopLevelConstants() {
        let code = """
        let maturityYears = 5.0
        let numSteps = 20
        let stepCount = Double(numSteps)
        let dt = maturityYears / stepCount
        let timeFraction = 2.0 / maturityYears
        """
        #expect(divisionLines(code) == [])
    }

    // MARK: - Shadowing

    @Test("A closure parameter shadows a constant of the same name")
    func flagsShadowingClosureParameter() {
        let code = """
        func scale(x: Double, ks: [Double]) -> [Double] {
            let d = 2.0
            let direct = x / d
            return ks.map { d in direct / Double(d) }
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A constant declared in an inner block does not reach the outer name")
    func flagsOuterNameAfterInnerBlock() {
        let code = """
        func scale(x: Double, flag: Bool) -> Double {
            let d = 0.0
            if flag {
                let d = 2.0
                return x / d
            }
            return x / d
        }
        """
        #expect(divisionLines(code) == [7])
    }

    // MARK: - max(x, literal) through a let

    @Test("let d = max(x, positiveLiteral) is a nonzero divisor")
    func clearsMaxThroughLet() {
        let code = """
        func z(t: Int, stepCount: Int) -> Float {
            let safeStepCount = max(Float(max(stepCount - 1, 1)), .leastNonzeroMagnitude)
            return Float(t) / safeStepCount * 2.0 - 1.0
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A let floored at one clears a divisor that also carries a subnormal floor")
    func clearsFlooredLetInsideSubnormalMax() {
        let code = """
        func theta(i: Int, resolution: Int) -> Float {
            let thetaSteps = max(resolution, 1)
            return Float(i) / max(Float(thetaSteps), .leastNonzeroMagnitude) * 2.0
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("Swift.max with a positive literal is a nonzero divisor")
    func clearsQualifiedMax() {
        let code = """
        func mean(sum: Double, n: Int) -> Double {
            let count = Swift.max(Double(n), 1)
            return sum * 100.0 / count
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("let d = max(x, 0) still fires")
    func flagsMaxWithZero() {
        let code = """
        func mean(sum: Double, n: Int) -> Double {
            let count = max(Double(n), 0)
            return sum * 100.0 / count
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("max(x, .leastNonzeroMagnitude) still fires: the quotient is infinite")
    func flagsSubnormalFloor() {
        let code = """
        func theta(i: Int, steps: Int) -> Float {
            return Float(i) / max(Float(steps), .leastNonzeroMagnitude)
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("A let bound to max(x, .leastNonzeroMagnitude) still fires")
    func flagsSubnormalFloorThroughLet() {
        let code = """
        func theta(i: Int, steps: Int) -> Float {
            let safe = max(Float(steps), Float.leastNonzeroMagnitude)
            return Float(i) / safe
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("max(x, .leastNormalMagnitude) still fires")
    func flagsLeastNormalFloor() {
        let code = """
        func theta(i: Int, steps: Int) -> Double {
            let safe = max(Double(steps), .leastNormalMagnitude)
            return Double(i) / safe
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("max(x, .ulpOfOne) is the documented epsilon floor and is accepted")
    func clearsUlpFloor() {
        let code = """
        func theta(i: Int, steps: Int) -> Double {
            let safe = max(Double(steps), .ulpOfOne)
            return Double(i) / safe
        }
        """
        #expect(divisionLines(code) == [])
    }

    // MARK: - Static and member constants

    @Test("A static let read by bare name inside its type is a nonzero divisor")
    func clearsStaticLetBareName() {
        let code = """
        enum Stream {
            private static let lcgModulus: UInt64 = 1 << 32
            static func unit(_ s1: UInt64) -> Double {
                let x = Double(s1) / Double(lcgModulus)
                return x
            }
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A static let read as Type.member is a nonzero divisor")
    func clearsStaticLetQualified() {
        let code = """
        final class RandomGenerator {
            private static let modulus: UInt64 = 1 << 32
            func next(_ raw: UInt64) -> Double {
                return Double(raw) / Double(RandomGenerator.modulus)
            }
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A static var still fires")
    func flagsStaticVar() {
        let code = """
        final class RandomGenerator {
            static var modulus: UInt64 = 1 << 32
            func next(_ raw: UInt64) -> Double {
                return Double(raw) / Double(RandomGenerator.modulus)
            }
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A static member of a type this file does not declare still fires")
    func flagsStaticOfUnknownType() {
        let code = """
        final class RandomGenerator {
            func next(_ raw: UInt64) -> Double {
                return Double(raw) / Double(Elsewhere.modulus)
            }
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A static let whose shift leaves its type's width still fires")
    func flagsOverwideShiftConstant() {
        let code = """
        enum Stream {
            static let wide: UInt64 = 1 << 64
            static let narrow: UInt8 = 1 << 8
            static func unit(_ s: UInt64) -> Double {
                let a = Double(s) / Double(wide)
                let b = Double(s) / Double(narrow)
                return a + b
            }
        }
        """
        #expect(divisionLines(code) == [5, 6])
    }

    // MARK: - Standard-library constants

    @Test("pi and the integer maxima are nonzero divisors")
    func clearsStandardConstants() {
        let code = """
        func convert(x: Double, bits: UInt64, seed: UInt64, y: Float) -> Double {
            let a = 0.5 + x / Double.pi
            let b = (x * 180.0 / .pi, x * 90.0 / .pi)
            let c = Double(bits) / Double(UInt64.max)
            let d = Double(Int64(bitPattern: seed)) / Double(Int64.max)
            let e = Double(bits) / Double(UInt32.max)
            return a + b.0 + c + d + e
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("An unsigned minimum and the smallest magnitudes still fire")
    func flagsZeroAndTinyStandardConstants() {
        let code = """
        func convert(x: Double, bits: UInt64) -> Double {
            let a = Double(bits) / Double(UInt64.min)
            let b = x / Double.leastNonzeroMagnitude
            let c = x / Double.zero
            return a + b + c
        }
        """
        #expect(divisionLines(code) == [2, 3, 4])
    }

    // MARK: - Literal arithmetic

    @Test("Literal arithmetic with a division in it is a nonzero divisor")
    func clearsLiteralQuotient() {
        let code = """
        func perMillisecond(seconds: Double) -> Double {
            let durationInDays: Double = seconds / 86_400.0
            let averageDaysPerMonth = 365.25 / 12.0
            let months = durationInDays / averageDaysPerMonth
            return months + 1.0 / (365.25 / 12.0 * 86_400_000.0)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A typed literal shift is a nonzero divisor")
    func clearsTypedShift() {
        let code = """
        func unit(raw: UInt64, state: UInt64) -> Double {
            let u1 = Double(raw >> 32) / Double(UInt64(1) << 32)
            let u2 = Double(state >> 33) / Double(UInt64(1) << 31)
            return u1 + u2
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A constant of a square root of constants is a nonzero divisor")
    func clearsSquareRootConstant() {
        let code = """
        func height(x: Double) -> Double {
            let sqrtTwoPi = sqrt(2.0 * Double.pi)
            return (1.0 / max(sqrtTwoPi, .leastNonzeroMagnitude)) * exp(-0.5 * x * x)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("Literal arithmetic that comes to zero still fires")
    func flagsLiteralArithmeticZero() {
        let code = """
        func broken(x: Double, bits: UInt64) -> Double {
            let a = 1.0 / (2.0 - 2.0)
            let b = x / Double(1 / 2)
            let c = 1.0 / (1 / 2)
            let d = Double(bits) / Double(1 << 64)
            let e = Double(bits) / Double(UInt64(1) << 64)
            return a + b + c + d + e
        }
        """
        #expect(divisionLines(code) == [2, 3, 4, 5, 6])
    }

    @Test("Literal arithmetic that is not a number is not a floor")
    func flagsNotANumberFloor() {
        let code = """
        func broken(x: Double) -> Double {
            let floor = 1e308 * 10.0 - 1e308 * 10.0
            return 1.0 / max(x, floor) + 1.0 / min(2.0, floor)
        }
        """
        #expect(divisionLines(code) == [3, 3])
    }

    @Test("An untyped shift past 31 bits still fires: Int is 32 bits on arm64_32")
    func flagsUntypedWideShift() {
        let code = """
        func unit(bits: UInt64) -> Double {
            let a = Double(bits) / Double(1 << 53)
            let b = Double(bits) / Double(UInt64(1) << 53)
            let c = Double(bits) / Double(1 << 20)
            return a + b + c
        }
        """
        #expect(divisionLines(code) == [2])
    }

    // MARK: - Where a constant is read from

    @Test("A stored let with an initializer and Self.member are read")
    func clearsStoredLetAndSelfMember() {
        let code = """
        struct Scaler {
            static let unitsPerTurn = 360.0
            let scale = 2.0
            func apply(_ x: Double) -> Double {
                return x / scale + x / Self.unitsPerTurn + x / self.scale
            }
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A stored var with an initializer is not read")
    func flagsStoredVar() {
        let code = """
        struct Scaler {
            var scale = 2.0
            func apply(_ x: Double) -> Double {
                return x / scale
            }
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A file-scope let is not read inside a type: a member declared elsewhere would be found first")
    func flagsGlobalInsideType() {
        let code = """
        let scale = 2.0
        func free(_ x: Double) -> Double { x / scale }
        extension Scaler {
            func apply(_ x: Double) -> Double { x / scale }
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A threshold that is a constant of this file is the literal it names")
    func clearsNamedThreshold() {
        let code = """
        func inverse(d: Double, limit: Double) -> Double {
            let epsilon = 1e-9
            guard d > epsilon else { return 0 }
            return 1.0 / d
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A threshold that is another value is not a threshold")
    func flagsParameterThreshold() {
        let code = """
        func inverse(d: Double, limit: Double) -> Double {
            guard d > limit else { return 0 }
            return 1.0 / d
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("greatestFiniteMagnitude is a nonzero divisor")
    func clearsGreatestFiniteMagnitude() {
        let code = """
        func normalised(_ x: Double) -> Double {
            return x / Double.greatestFiniteMagnitude
        }
        """
        #expect(divisionLines(code) == [])
    }

    // MARK: - What is deliberately not resolved

    @Test("A computed property of another value is not resolved")
    func flagsComputedPropertyThroughMember() {
        let code = """
        enum Frequency {
            case monthly, annual
            var periodsPerYear: Int {
                switch self {
                case .monthly: return 12
                case .annual: return 1
                }
            }
        }
        func periodicRate(rate: Double, frequency: Frequency) -> Double {
            return rate / Double(frequency.periodsPerYear)
        }
        """
        #expect(divisionLines(code) == [11])
    }
}
