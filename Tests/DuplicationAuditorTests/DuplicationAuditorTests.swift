import Foundation
import Testing
import QualityGateCore
@testable import DuplicationAuditor

// MARK: - Fixture sources

/// A ~68-token function used as the planted clone body across fixtures.
private let cloneFunction = """
func computeChecksum(values: [Int]) -> Int {
    var total = 0
    var count = 0
    for value in values {
        total = total + value * 3
        count = count + 1
        if total > 1000 {
            total = total - 500
        }
    }
    let scaled = total * 2 + count
    let bounded = scaled % 97
    return bounded + 11
}
"""

/// The same shape as `cloneFunction` with every identifier renamed.
private let renamedCloneFunction = """
func digestValue(items: [Int]) -> Int {
    var sum = 0
    var tally = 0
    for item in items {
        sum = sum + item * 3
        tally = tally + 1
        if sum > 1000 {
            sum = sum - 500
        }
    }
    let adjusted = sum * 2 + tally
    let clamped = adjusted % 97
    return clamped + 11
}
"""

/// Structurally distinct filler so file A shares nothing else with file B.
private let fillerA = """
struct AlphaContainer {
    let identifier: Int

    init(identifier: Int) {
        self.identifier = identifier
    }
}
"""

/// Structurally distinct filler for the second fixture file.
private let fillerB = """
enum BetaState {
    case idle
    case running

    var label: Int {
        switch self {
        case .idle:
            return 0
        case .running:
            return 1
        }
    }
}
"""

/// A short (~10 token) snippet, well under any realistic threshold.
private let shortShared = """
func makeZero() -> Int {
    return 0
}
"""

// MARK: - Fixture helpers

/// Creates a temporary package root containing the given Sources/ and Tests/ files.
private func makeRoot(sources: [String: String], tests: [String: String] = [:]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DuplicationAuditorTests-\(UUID().uuidString)", isDirectory: true)
    let sourcesDir = root.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
    for (name, contents) in sources {
        try contents.write(to: sourcesDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    if !tests.isEmpty {
        let testsDir = root.appendingPathComponent("Tests", isDirectory: true)
        try FileManager.default.createDirectory(at: testsDir, withIntermediateDirectories: true)
        for (name, contents) in tests {
            try contents.write(to: testsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
    return root
}

/// Best-effort removal of a temporary fixture root.
private func removeRoot(_ url: URL) {
    try? FileManager.default.removeItem(at: url) // silent: best-effort cleanup of a temp fixture directory
}

// MARK: - Tests

@Suite("DuplicationAuditor")
struct DuplicationAuditorTests {

    @Test("Exact clone across two files is flagged with both locations")
    func exactCloneAcrossTwoFiles() async throws {
        let root = try makeRoot(sources: [
            "Alpha.swift": fillerA + "\n\n" + cloneFunction,
            "Beta.swift": cloneFunction + "\n\n" + fillerB,
        ])
        defer { removeRoot(root) }

        let auditor = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 40),
            root: root.path
        )
        let result = try await auditor.check(configuration: Configuration())

        #expect(result.status == .passed)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(result.diagnostics.count == 1)
        #expect(diagnostic.ruleId == "duplication.clone")
        #expect(diagnostic.severity == .note)
        // fillerA occupies lines 1-7, a blank line 8, then the 14-line clone:
        // Alpha block is lines 9-22; in Beta the clone opens the file, lines 1-14.
        #expect(diagnostic.message.contains("Sources/Alpha.swift:9-22"))
        #expect(diagnostic.message.contains("Sources/Beta.swift:1-14"))
        #expect(diagnostic.message.contains("≈"))
        #expect(diagnostic.message.contains("-token clone"))
        let filePath = try #require(diagnostic.filePath)
        #expect(filePath.hasSuffix("Sources/Alpha.swift"))
        #expect(diagnostic.lineNumber == 9)
    }

    @Test("Renamed-identifier clone (same shape, different names) is flagged")
    func renamedIdentifierClone() async throws {
        let root = try makeRoot(sources: [
            "Alpha.swift": fillerA + "\n\n" + cloneFunction,
            "Beta.swift": renamedCloneFunction + "\n\n" + fillerB,
        ])
        defer { removeRoot(root) }

        let auditor = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 40),
            root: root.path
        )
        let result = try await auditor.check(configuration: Configuration())

        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.message.contains("Alpha.swift"))
        #expect(diagnostic.message.contains("Beta.swift"))
    }

    @Test("Near-duplicate shorter than minTokens is not flagged")
    func belowThresholdNotFlagged() async throws {
        let root = try makeRoot(sources: [
            "Alpha.swift": fillerA + "\n\n" + shortShared,
            "Beta.swift": fillerB + "\n\n" + shortShared,
        ])
        defer { removeRoot(root) }

        let auditor = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 60),
            root: root.path
        )
        let result = try await auditor.check(configuration: Configuration())

        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Overlapping seed windows merge into one maximal block pair")
    func overlappingWindowsMergeToOneBlock() async throws {
        // Identical ~90-token files with a 20-token window produce dozens of
        // seed windows; they must merge into a single maximal clone pair.
        let content = fillerA + "\n\n" + cloneFunction
        let root = try makeRoot(sources: [
            "Alpha.swift": content,
            "Beta.swift": content,
        ])
        defer { removeRoot(root) }

        let auditor = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 20),
            root: root.path
        )
        let result = try await auditor.check(configuration: Configuration())

        #expect(result.diagnostics.count == 1)
    }

    @Test("Threshold boundary: exactly minTokens flags, one token short does not")
    func thresholdBoundary() async throws {
        let tokenCount = CloneTokenizer.tokenize(source: cloneFunction).count
        let root = try makeRoot(sources: [
            "Alpha.swift": cloneFunction,
            "Beta.swift": cloneFunction,
        ])
        defer { removeRoot(root) }

        // Clone length == minTokens: flagged, with the exact token count named.
        let atThreshold = DuplicationAuditor(
            config: DuplicationConfig(minTokens: tokenCount),
            root: root.path
        )
        let flagged = try await atThreshold.check(configuration: Configuration())
        #expect(flagged.diagnostics.count == 1)
        let diagnostic = try #require(flagged.diagnostics.first)
        #expect(diagnostic.message.contains("\(tokenCount)-token clone"))

        // Clone length == minTokens - 1: not flagged.
        let aboveThreshold = DuplicationAuditor(
            config: DuplicationConfig(minTokens: tokenCount + 1),
            root: root.path
        )
        let clean = try await aboveThreshold.check(configuration: Configuration())
        #expect(clean.diagnostics.isEmpty)
    }

    @Test("Two runs over the same tree produce identical diagnostics")
    func deterministicAcrossRuns() async throws {
        let root = try makeRoot(sources: [
            "Alpha.swift": fillerA + "\n\n" + cloneFunction,
            "Beta.swift": cloneFunction + "\n\n" + fillerB,
            "Gamma.swift": renamedCloneFunction + "\n\n" + shortShared,
        ])
        defer { removeRoot(root) }

        let auditor = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 40),
            root: root.path
        )
        let first = try await auditor.check(configuration: Configuration())
        let second = try await auditor.check(configuration: Configuration())

        // Three pairwise clones: Alpha≈Beta, Alpha≈Gamma, Beta≈Gamma.
        #expect(first.diagnostics.count == 3)
        #expect(first.diagnostics == second.diagnostics)
    }

    @Test("Advisory posture: warnOnClones escalates severity and status")
    func warnOnClonesEscalates() async throws {
        let root = try makeRoot(sources: [
            "Alpha.swift": fillerA + "\n\n" + cloneFunction,
            "Beta.swift": cloneFunction + "\n\n" + fillerB,
        ])
        defer { removeRoot(root) }

        let advisory = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 40),
            root: root.path
        )
        #expect(advisory.id == "duplication")
        #expect(advisory.name == "Duplication Auditor")
        let noteResult = try await advisory.check(configuration: Configuration())
        #expect(noteResult.status == .passed)
        #expect(noteResult.diagnostics.allSatisfy { $0.severity == .note })

        let escalated = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 40, warnOnClones: true),
            root: root.path
        )
        let warningResult = try await escalated.check(configuration: Configuration())
        #expect(warningResult.status == .warning)
        #expect(warningResult.diagnostics.count == 1)
        #expect(warningResult.diagnostics.allSatisfy { $0.severity == .warning })
    }

    @Test("excludeTests skips clones that live under Tests/")
    func excludeTestsSkipsTestTree() async throws {
        let root = try makeRoot(
            sources: ["Alpha.swift": fillerA + "\n\n" + cloneFunction],
            tests: ["AlphaTests.swift": cloneFunction + "\n\n" + fillerB]
        )
        defer { removeRoot(root) }

        let including = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 40),
            root: root.path
        )
        let found = try await including.check(configuration: Configuration())
        #expect(found.diagnostics.count == 1)

        let excluding = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 40, excludeTests: true),
            root: root.path
        )
        let clean = try await excluding.check(configuration: Configuration())
        #expect(clean.diagnostics.isEmpty)
    }

    @Test("fingerprints() round-trips through Codable")
    func fingerprintsCodableRoundTrip() async throws {
        let root = try makeRoot(sources: [
            "Alpha.swift": fillerA + "\n\n" + cloneFunction,
        ])
        defer { removeRoot(root) }

        let auditor = DuplicationAuditor(
            config: DuplicationConfig(minTokens: 20),
            root: root.path
        )
        let fingerprints = try auditor.fingerprints()
        #expect(!fingerprints.isEmpty)
        for fingerprint in fingerprints {
            #expect(fingerprint.hash.count == 16)
            #expect(fingerprint.tokenCount == 20)
            #expect(fingerprint.startLine >= 1)
            #expect(fingerprint.endLine >= fingerprint.startLine)
            #expect(fingerprint.filePath.hasSuffix("Alpha.swift"))
        }

        let encoded = try JSONEncoder().encode(fingerprints)
        let decoded = try JSONDecoder().decode([CloneFingerprint].self, from: encoded)
        #expect(decoded == fingerprints)

        // Determinism: recomputing yields the identical fingerprint list.
        let again = try auditor.fingerprints()
        #expect(again == fingerprints)
    }

    @Test("DuplicationConfig decodes absent keys to defaults")
    func configDecodesWithDefaults() throws {
        let empty = try JSONDecoder().decode(DuplicationConfig.self, from: Data("{}".utf8))
        #expect(empty == DuplicationConfig())
        #expect(empty.minTokens == 80)
        #expect(empty.warnOnClones == false)
        #expect(empty.excludeTests == false)

        let partial = try JSONDecoder().decode(
            DuplicationConfig.self,
            from: Data(#"{"minTokens": 40}"#.utf8)
        )
        #expect(partial.minTokens == 40)
        #expect(partial.warnOnClones == false)
        #expect(partial.excludeTests == false)

        let full = try JSONDecoder().decode(
            DuplicationConfig.self,
            from: Data(#"{"minTokens": 25, "warnOnClones": true, "excludeTests": true}"#.utf8)
        )
        #expect(full == DuplicationConfig(minTokens: 25, warnOnClones: true, excludeTests: true))
    }
}
