import Foundation
import SwiftParser
import SwiftSyntax
import Testing
@testable import QualityGateCore
@testable import StochasticDeterminismAuditor

/// Which rule owns the line (`ASeedIsNotASecret.md` §3.6).
///
/// `stochastic-no-seed` asks for an injectable generator so a caller can reproduce the numbers.
/// For a bearer token that seam is the defect. So where a value is in a security context — the
/// same `SecurityContext` predicate the `security.*` rules use, reached through the same
/// `SecurityValueSite` — the stochastic rules stand down on the safe sources, and the security
/// rules own the line. Outside a security context nothing changes.
@Suite("Stochastic rules stand down in a security context")
struct SecurityOwnershipTests {

    private func diagnose(_ source: String, filePath: String = "Sources/App/test.swift") -> [Diagnostic] {
        let tree = Parser.parse(source: source)
        let visitor = StochasticVisitor(
            filePath: filePath,
            converter: SourceLocationConverter(fileName: filePath, tree: tree),
            sourceLines: source.lines)
        visitor.walk(tree)
        return visitor.diagnostics
    }

    private func ruleIds(_ source: String) -> [String] {
        diagnose(source).compactMap(\.ruleId)
    }

    @Test("6. let jitter = drand48() still reports stochastic-global-state")
    func jitterUnchanged() {
        #expect(ruleIds("func wait() { let jitter = drand48(); sleep(jitter) }") == ["stochastic-global-state"])
    }

    @Test("7. let token = arc4random() is not stochastic-global-state")
    func arc4randomTokenIsOwnedBySecurity() {
        #expect(ruleIds("func make() -> UInt32 { let token = arc4random(); return token }").isEmpty)
    }

    @Test("arc4random outside a security context is still reported")
    func arc4randomElsewhere() {
        #expect(ruleIds("func roll() -> UInt32 { let face = arc4random_uniform(6); return face }")
            == ["stochastic-global-state"])
    }

    @Test("10. A SystemRandomNumberGenerator behind a token is not stochastic-no-seed")
    func systemGeneratorBehindToken() {
        #expect(ruleIds("""
            func mint() -> String {
                var g = SystemRandomNumberGenerator()
                let token = generateToken(using: &g)
                return token
            }
            """).isEmpty)
    }

    @Test(".random(in:) making a nonce is not stochastic-no-seed")
    func randomNonce() {
        #expect(ruleIds("func nonce() -> UInt64 { let nonce = UInt64.random(in: 0 ... .max); return nonce }").isEmpty)
    }

    @Test(".random(in:) outside a security context is still stochastic-no-seed")
    func randomElsewhere() {
        #expect(ruleIds("func roll() -> Double { Double.random(in: 0...1) }") == ["stochastic-no-seed"])
    }

    @Test("SystemRandomNumberGenerator outside a security context is still stochastic-no-seed")
    func systemGeneratorElsewhere() {
        #expect(ruleIds("""
            func simulate() -> Double {
                var g = SystemRandomNumberGenerator()
                let sample = Double.random(in: 0...1, using: &g)
                return sample
            }
            """) == ["stochastic-no-seed"])
    }

    @Test("30. TokenStore.generateToken without its exempt marker is clean")
    func tokenStoreShape() {
        #expect(diagnose("""
            enum TokenStore {
                static let tokenByteCount = 32
                private static func generateToken() throws -> String {
                    var generator = SystemRandomNumberGenerator()
                    let bytes = (0..<tokenByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
                    guard bytes.count == tokenByteCount else {
                        throw TokenStoreError.entropyUnavailable(Int32(bytes.count))
                    }
                    return bytes.hexEncoded()
                }
            }
            """).isEmpty)
    }
}
