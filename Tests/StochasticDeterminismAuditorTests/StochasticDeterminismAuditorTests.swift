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
        sourceLines: source.components(separatedBy: "\n"),
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
        #expect(diag?.suggestedFix != nil)
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

    @Test("Per-line stochastic:exempt suppresses diagnostic")
    func perLineExemptSuppresses() {
        let code = """
        func simulate() {
            let x = Double.random(in: 0...1) // stochastic:exempt
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

    @Test("Test file paths are skipped")
    func testFilePathsSkipped() {
        let code = """
        func testSimulate() {
            let x = Double.random(in: 0...1)
        }
        """
        let results = diagnose(code, filePath: "Tests/MyTests/SimulationTests.swift")
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
        #expect(diag?.lineNumber != nil)
        #expect(diag?.lineNumber == 2)
    }
}
