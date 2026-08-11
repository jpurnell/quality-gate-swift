import Foundation
import QualityGateCore

/// Rewrites an assembled article so it reports what its documented values actually are.
///
/// ## Why injection rather than stdout capture
///
/// 81 of 99 claims in the measured corpus describe a binding that is never printed. Nothing
/// on stdout says what `pv` came out as, so nothing on stdout can check the claim under it.
/// The program has to be asked.
///
/// ## Why this does not break line attribution
///
/// ``AssembledArticle/articleLine(forAssembledLine:)`` resolves by walking back to the
/// nearest preceding `// >>> article line N` marker and adding the offset — so inserting a
/// line into the middle of a block would push every line after it one line too far. The way
/// around it needs no change to that method at all: **emit a fresh marker on each side of
/// the injection**. The one before carries the claim's own article line, so the assertion
/// reports where the claim is written; the one after carries the line the original code
/// resumes at, so every real statement keeps its own number.
///
/// This is the round trip most likely to be subtly wrong, and it is the reason rung 3 is
/// built on the assembler rather than beside it.
enum ClaimAssertionInjector {

    /// The name of the injected assertion, so a test can find it without matching whitespace.
    static let assertionFunction = "__qgClaim"

    /// The name of the injected stdout marker.
    static let markFunction = "__qgMark"

    /// The sentinel a stdout marker prints, so the line a transcript claim binds to can be
    /// located exactly rather than searched for.
    static let stdoutMark = "\u{1}QGMARK\u{1}"

    /// The sentinels as *escape sequences*, for writing into generated Swift source.
    ///
    /// The distinction is not cosmetic. Interpolating the raw sentinel puts a literal `0x01`
    /// byte into `main.swift`, and `swiftc` rejects the file outright with `unprintable ASCII
    /// character found in source file` — so every instrumented article fails to build, and
    /// the checker reports that no claim could be verified. The generated program must
    /// *spell* the control character, not contain it.
    static let escapedClaimSentinel = #"\u{1}QGCLAIM\u{1}"#
    static let escapedSeparator = #"\u{1}"#
    static let escapedStdoutMark = #"\u{1}QGMARK\u{1}"#

    /// The helper definitions prepended to an instrumented program.
    ///
    /// The overload set is the whole design. A catch-all `<T>` guarantees the program still
    /// compiles whatever the claimed binding turns out to be — a struct, an enum, a
    /// `TimeSeries` — and reports it as opaque rather than failing the build; the constrained
    /// overloads are more specialised, so Swift prefers them wherever a number or a sequence
    /// of numbers is what the claim is really about. Without the catch-all, one claim on a
    /// non-numeric binding would take the whole article's instrumentation down with it, and
    /// the checker would report a build failure where the honest answer is "not comparable".
    static let preamble = """
        // --- injected by doc-claims; not part of the article ---
        func __qgEmit(_ line: Int, _ shape: String, _ type: String, _ values: String) {
            let record = "\(escapedClaimSentinel)\\(line)\(escapedSeparator)\\(shape)\(escapedSeparator)\\(type)\(escapedSeparator)\\(values)\\n"
            FileHandle.standardError.write(Data(record.utf8))
        }
        func __qgClaim<T>(_ line: Int, _ value: T) {
            __qgEmit(line, "opaque", "\\(T.self)", "")
        }
        func __qgClaim<T: BinaryFloatingPoint>(_ line: Int, _ value: T) {
            __qgEmit(line, "scalar", "\\(T.self)", "\\(Double(value))")
        }
        func __qgClaim<T: BinaryInteger>(_ line: Int, _ value: T) {
            __qgEmit(line, "scalar", "\\(T.self)", "\\(Double(value))")
        }
        func __qgClaim<S: Sequence>(_ line: Int, _ value: S) where S.Element: BinaryFloatingPoint {
            __qgEmit(line, "sequence", "\\(S.self)", value.map { "\\(Double($0))" }.joined(separator: ","))
        }
        func __qgClaim<S: Sequence>(_ line: Int, _ value: S) where S.Element: BinaryInteger {
            __qgEmit(line, "sequence", "\\(S.self)", value.map { "\\(Double($0))" }.joined(separator: ","))
        }
        func __qgMark(_ line: Int) {
            print("\(escapedStdoutMark)\\(line)")
        }
        // --- end injected ---
        """

    /// One injected fragment: a marker carrying the claim's line, the code, and a marker
    /// restoring the original attribution.
    private struct Injection {
        let claimArticleLine: Int
        let code: String
        let resumeArticleLine: Int
    }

    /// Returns `assembled` with an assertion after every checkable value claim and a stdout
    /// marker before every checkable transcript claim.
    ///
    /// An article with no checkable claims comes back byte-identical, helpers and all
    /// omitted — instrumenting a program that has nothing to report would change what it
    /// compiles for no gain.
    ///
    /// - Parameter assembled: The program as `doc-code` and `doc-run` see it.
    /// - Returns: The instrumented program, with a line map that still resolves.
    static func inject(into assembled: AssembledArticle) -> AssembledArticle {
        var after: [Int: Injection] = [:]
        var before: [Int: Injection] = [:]

        for claim in assembled.claims where !claim.isExempt {
            switch (claim.kind, claim.anchor) {
            case (.value, .binding(let name)):
                after[claim.assembledLine] = Injection(
                    claimArticleLine: claim.articleLine,
                    code: "\(assertionFunction)(\(claim.articleLine), \(name))",
                    resumeArticleLine: claim.articleLine + 1)

            case (.transcript, .printStatement):
                // *Before* the print, not after it: the marker's job is to say where in
                // stdout the claimed line begins. A cursor that merely searches forward for
                // the expected text passes on the wrong line when the same label is printed
                // three times with three different values, which is exactly what
                // 3.9-EquityValuationGuide does.
                let anchorLine = assembled.articleLine(forAssembledLine: claim.anchorAssembledLine)
                before[claim.anchorAssembledLine] = Injection(
                    claimArticleLine: claim.articleLine,
                    code: "\(markFunction)(\(claim.articleLine))",
                    resumeArticleLine: anchorLine)

            default:
                continue
            }
        }

        guard !after.isEmpty || !before.isEmpty else { return assembled }

        var out: [String] = []
        var lineMap: [Int: Int] = [:]
        var preambleWritten = false

        func emit(_ injection: Injection) {
            out.append("// >>> article line \(injection.claimArticleLine)")
            lineMap[out.count] = injection.claimArticleLine
            out.append(injection.code)
            out.append("// >>> article line \(injection.resumeArticleLine)")
            lineMap[out.count] = injection.resumeArticleLine
        }

        for (index, line) in assembled.source.lines.enumerated() {
            let original = index + 1

            // The helpers go immediately before the first block, so they are in scope for
            // every statement and no article line moves relative to its own marker.
            if !preambleWritten, assembled.lineMap[original] != nil {
                out += preamble.lines
                preambleWritten = true
            }

            if let injection = before[original] { emit(injection) }

            if let base = assembled.lineMap[original] {
                out.append(line)
                lineMap[out.count] = base
            } else {
                out.append(line)
            }

            if let injection = after[original] { emit(injection) }
        }

        // A source that ends in a newline splits to a trailing empty element; joining and
        // re-terminating would double it.
        var source = out.joined(separator: "\n")
        if !source.hasSuffix("\n") { source += "\n" }

        return AssembledArticle(
            source: source,
            fencesFound: assembled.fencesFound,
            fencesChecked: assembled.fencesChecked,
            fencesExempt: assembled.fencesExempt,
            exemptFenceLines: assembled.exemptFenceLines,
            claims: assembled.claims,
            lineMap: lineMap)
    }

    /// stdout with the injected markers removed, and an index of where each claim's line is.
    ///
    /// - Parameter stdout: The instrumented program's output.
    /// - Returns: The article's real output, and a map from claim article line to that
    ///   line's index in the returned array.
    static func readMarks(_ stdout: String) -> (lines: [String], marks: [Int: Int]) {
        var lines: [String] = []
        var marks: [Int: Int] = [:]
        for line in DeterminismReport.outputLines(stdout) {
            guard line.hasPrefix(stdoutMark) else {
                lines.append(line)
                continue
            }
            guard let claimLine = Int(line.dropFirst(stdoutMark.count)) else { continue }
            // The claimed line is the next one the program prints. Recorded rather than
            // searched for, so a label printed three times with three different values binds
            // to the occurrence the claim was written under.
            marks[claimLine] = lines.count
        }
        return (lines, marks)
    }
}
