import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import StochasticDeterminismAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

/// Parses a Swift source string and runs the stochastic determinism visitor,
/// returning all collected diagnostics. Uses the visitor directly so tests
/// do not require filesystem access.
private func diagnose(
    _ source: String,
    filePath: String = "test.swift",
    flagCollectionShuffle: Bool = true,
    flagGlobalState: Bool = true,
    exemptFunctions: Set<String> = []
) -> [Diagnostic] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: filePath, tree: tree)
    let visitor = StochasticVisitor(
        filePath: filePath,
        converter: converter,
        sourceLines: source.lines,
        flagCollectionShuffle: flagCollectionShuffle,
        flagGlobalState: flagGlobalState,
        exemptFunctions: exemptFunctions
    )
    visitor.walk(tree)
    return visitor.diagnostics
}

// MARK: - Identity Tests

@Suite("StochasticDeterminismAuditor: Identity")
struct IdentityTests {
    @Test("Checker identity properties")
    func identity() {
        let auditor = StochasticDeterminismAuditor()
        #expect(auditor.id == "stochastic-determinism")
        #expect(auditor.name == "Stochastic Determinism Auditor")
    }
}

// MARK: - stochastic-no-seed Rule Tests

@Suite("StochasticDeterminismAuditor: stochastic-no-seed")
struct NoSeedTests {
    private let ruleId = "stochastic-no-seed"

    // MARK: - Must flag

    @Test("Flags .random(in:) without RNG parameter")
    func flagsRandomInWithoutRNG() {
        let code = """
        func simulate() {
            let x = Double.random(in: 0...1)
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags .random() without RNG parameter")
    func flagsRandomWithoutRNG() {
        let code = """
        func flip() {
            let coin = Bool.random()
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags SystemRandomNumberGenerator usage")
    func flagsSystemRNG() {
        let code = """
        func makeGenerator() {
            var rng = SystemRandomNumberGenerator()
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("A same-named callable with different argument labels is not flagged")
    func doesNotCollideOnBareName() {
        // BusinessMath declares `MonteCarloScenario.normal(mean:standardDeviation:numberOfScenarios:seed:)`
        // and, elsewhere, `ProbabilisticDriver.normal(name:mean:stdDev:)` which has no seed
        // at all. Matching on the bare name alone made every call to the second one a
        // finding — 42 of them in one suite, more than a quarter of the rule's output.
        let api = """
        public struct MonteCarloScenario {
            public static func normal(mean: [Double], standardDeviation: [Double], numberOfScenarios: Int, seed: UInt64? = nil) -> [Int] { [] }
        }
        """
        let code = """
        @Test func projects() {
            let driver = ProbabilisticDriver<Double>.normal(name: "Sales", mean: 1000.0, stdDev: 100.0)
        }
        """
        #expect(diagnoseUnseeded(code, declaring: api).isEmpty)
    }

    @Test("A call whose labels are a subset of the seedable signature is flagged")
    func matchesOnLabelSubset() {
        let api = """
        public struct MonteCarloScenario {
            public static func normal(mean: [Double], standardDeviation: [Double], numberOfScenarios: Int, seed: UInt64? = nil) -> [Int] { [] }
        }
        """
        let code = """
        @Test func scenarios() {
            let s = MonteCarloScenario.normal(mean: m, standardDeviation: sd, numberOfScenarios: 100)
        }
        """
        #expect(diagnoseUnseeded(code, declaring: api).count == 1)
    }

    @Test("Overloads are matched independently, not by the union of their labels")
    func overloadsMatchIndependently() {
        let api = """
        public struct Sim {
            public init(iterations: Int, seed: UInt64? = nil) {}
            public init(steps: Int, seed: UInt64? = nil) {}
        }
        """
        let mixed = """
        @Test func t() { let s = Sim(iterations: 10, steps: 3) }
        """
        #expect(diagnoseUnseeded(mixed, declaring: api).isEmpty)
        let single = """
        @Test func t() { let s = Sim(steps: 3) }
        """
        #expect(diagnoseUnseeded(single, declaring: api).count == 1)
    }

    @Test("An unlabelled argument does not block a match")
    func unlabelledArgumentsAreWildcards() {
        let api = """
        public func integrate(_ f: (Double) -> Double, iterations: Int = 10_000, seed: UInt64? = nil) -> Double { 0 }
        """
        let code = """
        @Test func integrates() {
            let area = integrate({ $0 * $0 }, iterations: 1_000)
        }
        """
        #expect(diagnoseUnseeded(code, declaring: api).count == 1)
    }

    @Test("Diagnostic severity is warning")
    func diagnosticSeverityIsWarning() {
        let code = """
        func simulate() {
            let x = Double.random(in: 0...1)
        }
        """
        let results = diagnose(code)
        let diag = results.first { $0.ruleId == ruleId }
        #expect(diag?.severity == .warning)
    }

    @Test("Diagnostic includes suggested fix")
    func diagnosticIncludesSuggestedFix() {
        let code = """
        func simulate() {
            let x = Double.random(in: 0...1)
        }
        """
        let results = diagnose(code)
        let diag = results.first { $0.ruleId == ruleId }
        #expect(diag?.suggestedFix?.isEmpty == false)
    }

    // MARK: - Must pass

    @Test("Passes when function has inout some RandomNumberGenerator parameter")
    func passesWithSomeRNG() {
        let code = """
        func simulate(using rng: inout some RandomNumberGenerator) {
            let x = Double.random(in: 0...1, using: &rng)
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Passes when function has generic RNG parameter")
    func passesWithGenericRNG() {
        let code = """
        func simulate<G: RandomNumberGenerator>(using rng: inout G) {
            let x = Double.random(in: 0...1, using: &rng)
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Passes when function has RNG in where clause")
    func passesWithWhereClauseRNG() {
        let code = """
        func simulate<G>(using rng: inout G) where G: RandomNumberGenerator {
            let x = Double.random(in: 0...1, using: &rng)
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("UUID() is not flagged")
    func uuidIsExempt() {
        let code = """
        func makeId() {
            let id = UUID()
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty)
    }
}

// MARK: - stochastic-global-state Rule Tests

@Suite("StochasticDeterminismAuditor: stochastic-global-state")
struct GlobalStateTests {
    private let ruleId = "stochastic-global-state"

    @Test("Flags arc4random_uniform")
    func flagsArc4randomUniform() {
        let code = """
        func roll() {
            let n = arc4random_uniform(6)
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags arc4random")
    func flagsArc4random() {
        let code = """
        func randomValue() {
            let n = arc4random()
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags drand48")
    func flagsDrand48() {
        let code = """
        func randomDouble() {
            let x = drand48()
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags srand48")
    func flagsSrand48() {
        let code = """
        func seedRandom() {
            srand48(42)
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Not flagged when flagGlobalState is disabled")
    func notFlaggedWhenDisabled() {
        let code = """
        func roll() {
            let n = arc4random_uniform(6)
        }
        """
        let results = diagnose(code, flagGlobalState: false)
        #expect(!results.contains { $0.ruleId == ruleId })
    }
}

// MARK: - stochastic-collection-shuffle Rule Tests

@Suite("StochasticDeterminismAuditor: stochastic-collection-shuffle")
struct CollectionShuffleTests {
    private let ruleId = "stochastic-collection-shuffle"

    @Test("Flags .shuffled() without using: parameter")
    func flagsShuffledWithoutUsing() {
        let code = """
        func mix() {
            let items = [1, 2, 3].shuffled()
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags .shuffle() without using: parameter")
    func flagsShuffleWithoutUsing() {
        let code = """
        func mix() {
            var items = [1, 2, 3]
            items.shuffle()
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Passes .shuffled(using:) with RNG parameter")
    func passesShuffledWithUsing() {
        let code = """
        func mix(using rng: inout some RandomNumberGenerator) {
            let items = [1, 2, 3].shuffled(using: &rng)
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Not flagged when flagCollectionShuffle is disabled")
    func notFlaggedWhenDisabled() {
        let code = """
        func mix() {
            let items = [1, 2, 3].shuffled()
        }
        """
        let results = diagnose(code, flagCollectionShuffle: false)
        #expect(!results.contains { $0.ruleId == ruleId })
    }
}

// MARK: - Exemption Tests

@Suite("StochasticDeterminismAuditor: Exemptions")
struct ExemptionTests {

    // The markers below carry reasons because a bare one is now itself a finding
    // (`stochastic.exempt-no-justification`). These tests are about suppression, which is
    // unchanged; the bare case has its own suite.
    @Test("Per-line stochastic:exempt suppresses diagnostic")
    func perLineExemptSuppresses() {
        let code = """
        func simulate() {
            let x = Double.random(in: 0...1) // stochastic:exempt — environmental jitter, no seeded sibling exists
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty)
    }

    @Test("Exempt function name suppresses diagnostic")
    func exemptFunctionSuppresses() {
        let code = """
        func generateNoise() {
            let x = Double.random(in: 0...1)
        }
        """
        let results = diagnose(code, exemptFunctions: ["generateNoise"])
        #expect(results.isEmpty)
    }

    @Test("SecRandomCopyBytes is not flagged")
    func secRandomExempt() {
        let code = """
        func generateKey() {
            SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == "stochastic-no-seed" })
    }
}

// MARK: - Test-File Coverage

/// The visitor used to return `.skipChildren` for anything under `Tests/`, so none of
/// the three rules could see a test file. That was over-broad: it also surrendered the
/// rules `TestQualityAuditor` does *not* implement.
///
/// The division of labour that remains is deliberate. `TestQualityAuditor`'s
/// `unseeded-random` already covers `.random(…)`, `.shuffled(…)` and
/// `SystemRandomNumberGenerator` in test code, so this auditor stays silent on those to
/// avoid two checkers warning on one line. It claims what nothing else audits: C-style
/// global RNG state, and the in-place `.shuffle()` spelling that `unseeded-random`'s
/// `"shuffled"` match misses.
private let testPath = "Tests/MyPackageTests/SimulationTests.swift"

@Suite("StochasticDeterminismAuditor: Test-file coverage")
struct TestFileCoverageTests {

    @Test("Flags arc4random in a test file")
    func flagsGlobalStateInTests() {
        let code = """
        @Test func rolls() {
            let n = arc4random_uniform(6)
        }
        """
        let results = diagnose(code, filePath: testPath)
        #expect(results.contains { $0.ruleId == "stochastic-global-state" })
    }

    @Test("Flags drand48 in a test file")
    func flagsDrand48InTests() {
        let code = """
        @Test func draws() {
            let x = drand48()
        }
        """
        let results = diagnose(code, filePath: testPath)
        #expect(results.contains { $0.ruleId == "stochastic-global-state" })
    }

    @Test("Flags in-place .shuffle() in a test file")
    func flagsInPlaceShuffleInTests() {
        let code = """
        @Test func mixes() {
            var items = [1, 2, 3]
            items.shuffle()
        }
        """
        let results = diagnose(code, filePath: testPath)
        #expect(results.contains { $0.ruleId == "stochastic-collection-shuffle" })
    }

    @Test("Global-state advice in a test file does not say 'inject'")
    func globalStateFixIsTestShaped() {
        let code = """
        @Test func rolls() {
            let n = arc4random_uniform(6)
        }
        """
        let diag = diagnose(code, filePath: testPath).first { $0.ruleId == "stochastic-global-state" }
        let fix = try? #require(diag?.suggestedFix)
        #expect(fix?.contains("seed") == true)
        #expect(fix?.contains("inject") == false)
    }

    @Test("Shuffle advice in a test file does not say 'injected'")
    func shuffleFixIsTestShaped() {
        let code = """
        @Test func mixes() {
            var items = [1, 2, 3]
            items.shuffle()
        }
        """
        let diag = diagnose(code, filePath: testPath).first { $0.ruleId == "stochastic-collection-shuffle" }
        let fix = try? #require(diag?.suggestedFix)
        #expect(fix?.contains("seed") == true)
        #expect(fix?.contains("injected") == false)
    }

    @Test("Source-file advice keeps its original 'inject' wording")
    func sourceFixUnchanged() {
        let code = """
        func roll() {
            let n = arc4random_uniform(6)
        }
        """
        let diag = diagnose(code, filePath: "Sources/Sim/Engine.swift").first { $0.ruleId == "stochastic-global-state" }
        #expect(diag?.suggestedFix?.contains("inject a `RandomNumberGenerator`") == true)
    }

    // MARK: - Ceded to TestQualityAuditor's `unseeded-random`

    @Test(".random() in a test file is left to unseeded-random")
    func randomInTestsNotDuplicated() {
        let code = """
        @Test func draws() {
            let x = Double.random(in: 0...1)
        }
        """
        let results = diagnose(code, filePath: testPath)
        #expect(!results.contains { $0.ruleId == "stochastic-no-seed" })
    }

    @Test("SystemRandomNumberGenerator in a test file is left to unseeded-random")
    func systemRNGInTestsNotDuplicated() {
        let code = """
        @Test func draws() {
            var rng = SystemRandomNumberGenerator()
        }
        """
        let results = diagnose(code, filePath: testPath)
        #expect(!results.contains { $0.ruleId == "stochastic-no-seed" })
    }

    @Test(".shuffled() in a test file is left to unseeded-random")
    func shuffledInTestsNotDuplicated() {
        let code = """
        @Test func mixes() {
            let items = [1, 2, 3].shuffled()
        }
        """
        let results = diagnose(code, filePath: testPath)
        #expect(!results.contains { $0.ruleId == "stochastic-collection-shuffle" })
    }

    @Test("Per-line stochastic:exempt still suppresses in a test file")
    func exemptStillWorksInTests() {
        let code = """
        @Test func rolls() {
            let n = arc4random_uniform(6) // stochastic:exempt — this fixture is about the marker, not reproducibility
        }
        """
        let results = diagnose(code, filePath: testPath)
        #expect(results.isEmpty)
    }

    @Test("auditTests defaults to true")
    func auditTestsDefaultsTrue() {
        #expect(StochasticDeterminismConfig.default.auditTests)
    }
}

// MARK: - Edge Cases

@Suite("StochasticDeterminismAuditor: Edge Cases")
struct EdgeCaseTests {

    @Test("Empty source produces no diagnostics")
    func emptySource() {
        let results = diagnose("")
        #expect(results.isEmpty)
    }

    @Test("Source with no randomness produces no diagnostics")
    func noRandomness() {
        let code = """
        func greet(name: String) -> String {
            return "Hello, \\(name)"
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty)
    }

    @Test("Nested function inherits its own RNG status")
    func nestedFunctionOwnRNG() {
        let code = """
        func outer(using rng: inout some RandomNumberGenerator) {
            func inner() {
                let x = Double.random(in: 0...1)
            }
        }
        """
        let results = diagnose(code)
        // inner() does NOT have an RNG parameter, so it should be flagged
        #expect(results.contains { $0.ruleId == "stochastic-no-seed" })
    }

    @Test("Multiple diagnostics from same function")
    func multipleDiagnostics() {
        let code = """
        func chaos() {
            let x = Double.random(in: 0...1)
            let y = Int.random(in: 1...6)
            let items = [1, 2, 3].shuffled()
        }
        """
        let results = diagnose(code)
        #expect(results.count >= 3)
    }

    @Test("Diagnostic includes file path")
    func diagnosticIncludesFilePath() {
        let code = """
        func simulate() {
            let x = Double.random(in: 0...1)
        }
        """
        let results = diagnose(code, filePath: "Sources/Sim/Engine.swift")
        let diag = results.first
        #expect(diag?.filePath == "Sources/Sim/Engine.swift")
    }

    @Test("Diagnostic includes line number")
    func diagnosticIncludesLineNumber() {
        let code = """
        func simulate() {
            let x = Double.random(in: 0...1)
        }
        """
        let results = diagnose(code)
        let diag = results.first
        #expect(diag?.lineNumber == 2)
    }
}

// MARK: - stochastic-unseeded-test-call

/// Harvests seedable API names from a source string, as pass 1 does over `Sources/`.
private func harvest(_ source: String) -> Set<String> {
    let tree = Parser.parse(source: source)
    let harvester = SeedableAPIHarvester(viewMode: .sourceAccurate)
    harvester.walk(tree)
    // Projected here rather than on the harvester: production reads `seedableSignatures`,
    // and a convenience accessor no production code wants is dead weight the `unreachable`
    // checker is right to flag.
    return Set(harvester.seedableSignatures.map(\.name))
}

/// Runs pass 2 over a source string with a given harvest.
private func harvestSignatures(_ source: String) -> Set<SeedableSignature> {
    let tree = Parser.parse(source: source)
    let harvester = SeedableAPIHarvester(viewMode: .sourceAccurate)
    harvester.walk(tree)
    return harvester.seedableSignatures
}

/// The seedable surface most of the pass-2 tests are written against, in the shape
/// BusinessMath actually declares it.
private let monteCarloAPI = """
public struct MonteCarloSimulation {
    public init(iterations: Int, enableGPU: Bool = true, seed: UInt64? = nil, model: @escaping ([Double]) -> Double) {}
    public init() {}
}
public struct MonteCarloGPUDevice {
    public func runSimulation(distributions: [D], modelBytecode: [M], iterations: Int, seed: UInt64? = nil) throws -> [Float] { [] }
}
"""

/// Runs both passes the way the checker does: harvest from `declaring`, then check `source`.
private func diagnoseUnseeded(
    _ source: String,
    declaring apiSource: String = monteCarloAPI,
    filePath: String = "Tests/MyPackageTests/SimulationTests.swift"
) -> [Diagnostic] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: filePath, tree: tree)
    let visitor = UnseededSeedCallVisitor(
        seedableSignatures: harvestSignatures(apiSource),
        filePath: filePath,
        converter: converter,
        sourceLines: source.lines
    )
    visitor.walk(tree)
    return visitor.diagnostics
}

/// Pass 1: what a project declares as seedable, learned from the project itself.
///
/// There is no type information in a SwiftSyntax tree, and none is needed. A call site
/// that omits `seed:` can only be judged against the set of callables that *have* a
/// `seed:` to omit, and that set is discoverable by reading the declarations.
@Suite("StochasticDeterminismAuditor: seedable-API harvest")
struct SeedableAPIHarvestTests {

    @Test("An initializer is harvested under its enclosing type's name")
    func harvestsInitializerAsTypeName() {
        let code = """
        public struct MonteCarloSimulation {
            public init(iterations: Int, seed: UInt64? = nil) {}
        }
        """
        #expect(harvest(code) == ["MonteCarloSimulation"])
    }

    @Test("A method is harvested under its own base name")
    func harvestsMethodBaseName() {
        let code = """
        public struct MonteCarloGPUDevice {
            public func runSimulation(iterations: Int, seed: UInt64? = nil) throws -> [Float] { [] }
        }
        """
        #expect(harvest(code) == ["runSimulation"])
    }

    @Test("A free function is harvested under its own name")
    func harvestsFreeFunction() {
        let code = """
        public func integrate(iterations: Int = 10_000, seed: UInt64? = nil) -> Double { 0 }
        """
        #expect(harvest(code) == ["integrate"])
    }

    @Test("A seed parameter with no default is not harvested")
    func requiresDefaultValue() {
        let code = """
        public struct Sim {
            public init(iterations: Int, seed: UInt64) {}
        }
        public func draw(seed: UInt64) -> Double { 0 }
        """
        #expect(harvest(code).isEmpty)
    }

    @Test("A callable with no seed parameter is not harvested")
    func ignoresSeedlessCallables() {
        let code = """
        public struct Sim {
            public init(iterations: Int) {}
            public func run() throws {}
        }
        """
        #expect(harvest(code).isEmpty)
    }

    @Test("An initializer in a class, actor or enum is harvested too")
    func harvestsAllTypeKinds() {
        let code = """
        public final class A { public init(seed: UInt64? = nil) {} }
        public actor B { public init(seed: UInt64? = nil) {} }
        public enum C { public init(seed: UInt64? = nil) { self = .x } }
        public extension D { init(seed: UInt64? = nil) { self.init() } }
        """
        #expect(harvest(code) == ["A", "B", "C", "D"])
    }

    @Test("A nested type is harvested under the innermost type name")
    func harvestsInnermostTypeName() {
        let code = """
        public enum Namespace {
            public struct Runner {
                public init(seed: UInt64? = nil) {}
            }
        }
        """
        #expect(harvest(code) == ["Runner"])
    }

    @Test("A signature records the other argument labels alongside the name")
    func harvestsArgumentLabels() {
        let code = """
        public struct MonteCarloScenario {
            public static func normal(mean: [Double], standardDeviation: [Double], numberOfScenarios: Int, seed: UInt64? = nil) -> [Int] { [] }
        }
        """
        let signature = harvestSignatures(code).first
        #expect(signature?.name == "normal")
        #expect(signature?.labels == ["mean", "standardDeviation", "numberOfScenarios", "seed"])
    }

    @Test("The seed label is matched, not a parameter merely named seed internally")
    func matchesExternalLabel() {
        let code = """
        public func run(from seed: UInt64 = 0) {}
        public func go(seed value: UInt64 = 0) {}
        """
        #expect(harvest(code) == ["go"])
    }
}

/// Pass 2: a call to a harvested name that omits `seed:`.
@Suite("StochasticDeterminismAuditor: stochastic-unseeded-test-call")
struct UnseededTestCallTests {
    private let ruleId = "stochastic-unseeded-test-call"

    @Test("Flags an initializer call that omits seed:")
    func flagsUnseededInitializer() {
        let code = """
        @Test func meanIsCentred() throws {
            var sim = MonteCarloSimulation(iterations: 100, enableGPU: true)
            #expect(try sim.run().mean > 1400)
        }
        """
        let results = diagnoseUnseeded(code)
        #expect(results.count == 1)
        #expect(results.first?.ruleId == ruleId)
        #expect(results.first?.lineNumber == 2)
    }

    @Test("Flags a method call that omits seed:")
    func flagsUnseededMethod() {
        let code = """
        @Test func passthrough() throws {
            let results = try device.runSimulation(distributions: d, iterations: 100)
        }
        """
        let results = diagnoseUnseeded(code)
        #expect(results.count == 1)
    }

    @Test("Flags a call whose seed: sits behind a trailing closure")
    func flagsTrailingClosureCall() {
        let code = """
        @Test func modelled() throws {
            let sim = MonteCarloSimulation(iterations: 100) { inputs in inputs[0] }
        }
        """
        let results = diagnoseUnseeded(code)
        #expect(results.count == 1)
    }

    @Test("Passes when seed: is supplied")
    func passesWhenSeeded() {
        let code = """
        @Test func meanIsCentred() throws {
            var sim = MonteCarloSimulation(iterations: 100, seed: 0x5EED_1234)
        }
        """
        #expect(diagnoseUnseeded(code).isEmpty)
    }

    @Test("Passes when seed: is supplied on a later line of a multi-line call")
    func passesWhenSeededAcrossLines() {
        let code = """
        @Test func passthrough() throws {
            let results = try device.runSimulation(
                distributions: d,
                iterations: 100,
                seed: 0x5EED_1234
            )
        }
        """
        #expect(diagnoseUnseeded(code).isEmpty)
    }

    @Test("Passes for a callable the harvest never saw")
    func passesForUnharvestedName() {
        let code = """
        @Test func other() {
            let x = SomethingElse(iterations: 100)
        }
        """
        #expect(diagnoseUnseeded(code).isEmpty)
    }

    @Test("A zero-argument call is not flagged")
    func ignoresZeroArgumentCall() {
        let code = """
        @Test func empty() {
            let sim = MonteCarloSimulation()
        }
        """
        #expect(diagnoseUnseeded(code).isEmpty)
    }

    @Test("Diagnostic severity is warning")
    func severityIsWarning() {
        let code = """
        @Test func t() { let sim = MonteCarloSimulation(iterations: 100) }
        """
        #expect(diagnoseUnseeded(code).first?.severity == .warning)
    }

    @Test("Message names the callee and states the risk")
    func messageStatesRisk() {
        let code = """
        @Test func t() { let sim = MonteCarloSimulation(iterations: 100) }
        """
        let message = diagnoseUnseeded(code).first?.message ?? ""
        #expect(message.contains("MonteCarloSimulation"))
        #expect(message.contains("seed:"))
        #expect(message.contains("most draws"))
    }

    @Test("Suggested fix offers both the seed and the marker")
    func fixOffersBothRoutes() {
        let code = """
        @Test func t() { let sim = MonteCarloSimulation(iterations: 100) }
        """
        let fix = diagnoseUnseeded(code).first?.suggestedFix ?? ""
        #expect(fix.contains("seed:"))
        #expect(fix.contains("Justification:"))
    }
}

/// The opt-out. Some tests are *about* unseeded behaviour and must stay unseeded;
/// flagging those is the false positive that trains people to ignore the rule.
@Suite("StochasticDeterminismAuditor: unseeded-test-call opt-out")
struct UnseededTestCallOptOutTests {

    @Test("A justification on the preceding line suppresses")
    func justificationAboveSuppresses() {
        let code = """
        @Test func unseededCustomSamplerWorks() throws {
            // Justification: this test asserts that omitting the seed still produces a
            let sim = MonteCarloSimulation(iterations: 100)
        }
        """
        #expect(diagnoseUnseeded(code).isEmpty)
    }

    @Test("An inline justification on the call line suppresses")
    func inlineJustificationSuppresses() {
        let code = """
        @Test func t() throws {
            let sim = MonteCarloSimulation(iterations: 100) // Justification: unseeded is precisely what this test is checking here
        }
        """
        #expect(diagnoseUnseeded(code).isEmpty)
    }

    @Test("A bare marker with no stated reason does not suppress")
    func bareMarkerDoesNotSuppress() {
        let code = """
        @Test func t() throws {
            // Justification:
            let sim = MonteCarloSimulation(iterations: 100)
        }
        """
        let results = diagnoseUnseeded(code)
        #expect(results.count == 1)
        #expect(results.first?.message.contains("does not state a reason") == true)
    }

    @Test("A generic marker phrase does not suppress")
    func genericMarkerDoesNotSuppress() {
        let code = """
        @Test func t() throws {
            // Justification: safe
            let sim = MonteCarloSimulation(iterations: 100)
        }
        """
        #expect(diagnoseUnseeded(code).count == 1)
    }

    @Test("The bare stochastic:exempt marker does not suppress this rule")
    func exemptMarkerDoesNotSuppress() {
        let code = """
        @Test func t() throws {
            let sim = MonteCarloSimulation(iterations: 100) // stochastic:exempt
        }
        """
        #expect(diagnoseUnseeded(code).count == 1)
    }

    @Test("flagUnseededTestCalls defaults to true")
    func configDefaultsTrue() {
        #expect(StochasticDeterminismConfig.default.flagUnseededTestCalls)
    }
}
