import Foundation
import Testing
import QualityGateCore
@testable import SafetyAuditor

/// One `SourceLocationConverter` per file, and the locations it produces are unchanged.
///
/// `SafetyVisitor` and `SecurityVisitor` built a converter **per visited node**, from
/// `node.root` — the whole file's tree — so each construction indexed every line start. That is
/// O(file) per node, and it made `safety` quadratic: measured n²·⁰¹ against `concurrency`'s
/// n⁰·⁶³ on byte-identical input, 214s for a 259 KB file.
///
/// These tests pin the property that makes the fix safe rather than merely fast: a shared
/// converter changes **when** the index is built, not **what** it computes. Location correctness
/// under CRLF, a BOM, and multi-byte characters is exactly where a line index goes wrong, so
/// that is what is asserted.
@Suite("Shared location converter")
struct SharedConverterTests {

    private func findings(_ source: String) async throws -> [(rule: String, line: Int, column: Int)] {
        let result = try await SafetyAuditor().auditSource(
            source, fileName: "probe.swift", configuration: Configuration())
        return result.diagnostics.compactMap {
            guard let line = $0.lineNumber, let column = $0.columnNumber else { return nil }
            return ($0.ruleId ?? "?", line, column)
        }
    }

    /// Multiple findings in one file must each report their own location, not the first one's.
    ///
    /// The failure a shared converter could plausibly introduce: reusing a stale index and
    /// reporting every finding at the same place.
    @Test("Each finding keeps its own line and column")
    func distinctLocations() async throws {
        let found = try await findings("""
        let a: Int? = nil
        let x = a!
        let y = a!
        let z = a!
        """)
        let unwraps = found.filter { $0.rule.contains("force-unwrap") }
        #expect(unwraps.count == 3)
        #expect(Set(unwraps.map(\.line)).count == 3, "findings collapsed onto one line: \(unwraps)")
        #expect(unwraps.map(\.line).sorted() == [2, 3, 4])
    }

    /// CRLF is where a line index is most likely to be wrong.
    @Test("CRLF line endings report the same lines as LF")
    func crlfMatchesLF() async throws {
        let lf   = "let a: Int? = nil\nlet x = a!\nlet y = a!\n"
        let crlf = "let a: Int? = nil\r\nlet x = a!\r\nlet y = a!\r\n"
        let lfLines   = try await findings(lf).filter   { $0.rule.contains("force-unwrap") }.map(\.line)
        let crlfLines = try await findings(crlf).filter { $0.rule.contains("force-unwrap") }.map(\.line)
        #expect(lfLines == crlfLines, "CRLF shifted the reported lines: \(lfLines) vs \(crlfLines)")
        #expect(crlfLines == [2, 3])
    }

    /// A BOM occupies bytes before the first line and must not shift it.
    @Test("A leading BOM does not shift reported lines")
    func bomDoesNotShift() async throws {
        let withBOM = "\u{FEFF}let a: Int? = nil\nlet x = a!\n"
        let lines = try await findings(withBOM).filter { $0.rule.contains("force-unwrap") }.map(\.line)
        #expect(lines == [2], "BOM shifted the line: \(lines)")
    }

    /// Multi-byte characters must not shift columns, which are measured in UTF-8 bytes.
    @Test("Multi-byte characters before a finding keep its column stable")
    func multiByteColumns() async throws {
        let ascii = "let café = 1\nlet a: Int? = nil\nlet x = a!\n"
        let emoji = "let 🇯🇵 = 1\nlet a: Int? = nil\nlet x = a!\n"
        let a = try await findings(ascii).filter { $0.rule.contains("force-unwrap") }
        let e = try await findings(emoji).filter { $0.rule.contains("force-unwrap") }
        #expect(a.map(\.line) == e.map(\.line))
        #expect(a.map(\.column) == e.map(\.column),
                "a multi-byte character on an earlier line moved a later column")
    }

    /// The security rules share the same converter; their locations must be right too.
    @Test("Security findings report their own locations")
    func securityLocations() async throws {
        var config = Configuration()
        config.security.enabledRules = ["security.hardcoded-secret"]
        let result = try await SafetyAuditor().auditSource("""
        let harmless = 1
        let apiKey = "sk-abc123def456"
        """, fileName: "probe.swift", configuration: config)
        let secret = result.diagnostics.first { $0.ruleId == "security.hardcoded-secret" }
        #expect(secret?.lineNumber == 2, "expected line 2, got \(secret?.lineNumber as Any)")
    }
}
