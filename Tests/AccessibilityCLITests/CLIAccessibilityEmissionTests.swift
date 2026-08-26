import Testing
import AccessibilityCore
import QualityGateCore
@testable import AccessibilityCLI

/// Which escape literals count as *output*.
///
/// The `a11y.cli.*` rules are about what a program writes to a terminal. A constant that
/// names `ESC[31m`, or a function that returns it, writes nothing — the caller decides
/// whether to write it and whether to gate that on the user's preference. Firing on every
/// literal made every terminal library a wall of findings for having a vocabulary.
@Suite("CLIAccessibilityDetector — only emitted escapes are findings")
struct CLIAccessibilityEmissionTests {

    private func findings(_ source: String) -> [Diagnostic] {
        CLIAccessibilityDetector()
            .detect(in: SourceUnit(fileName: "Probe.swift", source: source, exemptionPatterns: []))
            .diagnostics
    }

    // MARK: - Vocabulary is not emission

    @Test("A constant declaration naming an escape is not an emission")
    func constantDeclaration() {
        #expect(findings(#"public static let red = "\u{001B}[31m""#).isEmpty)
    }

    @Test("An explicit return of an escape is not an emission")
    func explicitReturn() {
        let source = #"""
        func escape() -> String {
            return "\u{001B}[31m"
        }
        """#
        #expect(findings(source).isEmpty)
    }

    @Test("An implicit-return builder is not an emission")
    func implicitReturn() {
        let source = #"""
        func fg256(_ index: UInt8) -> String { "\u{001B}[38;5;\(index)m" }
        """#
        #expect(findings(source).isEmpty)
    }

    @Test("A cursor-control constant is not an emission")
    func cursorConstant() {
        #expect(findings(#"public static let show = "\u{001B}[?25h""#).isEmpty)
    }

    // MARK: - Reaching a write is emission

    @Test("print() of a color escape is an emission")
    func printedColor() {
        let source = #"func go() { print("\u{001B}[31mred") }"#
        #expect(findings(source).contains { $0.ruleId == "a11y.cli.no-color-not-respected" })
    }

    @Test("A write helper receiving a cursor escape is an emission")
    func writtenCursorControl() {
        let source = #"""
        func enter() {
            writeEscape("\u{001B}[?1049h")
        }
        """#
        #expect(findings(source).contains { $0.ruleId == "a11y.cli.cursor-control-no-tty" })
    }

    @Test("An escape concatenated into a printed expression is an emission")
    func concatenatedIntoPrint() {
        let source = #"""
        func go(_ text: String) {
            print("\u{001B}[31m" + text)
        }
        """#
        #expect(findings(source).contains { $0.ruleId == "a11y.cli.no-color-not-respected" })
    }

    @Test("An escape interpolated into a written string is an emission")
    func interpolatedIntoWrite() {
        let source = #"""
        func go(_ handle: FileHandle, _ text: String) {
            handle.write(Data("\u{001B}[31m\(text)".utf8))
        }
        """#
        #expect(findings(source).contains { $0.ruleId == "a11y.cli.no-color-not-respected" })
    }

    // MARK: - A guarded emission is still not a finding

    @Test("An emission that consults NO_COLOR is not a finding")
    func guardedEmission() {
        let source = #"""
        func go() {
            guard ProcessInfo.processInfo.environment["NO_COLOR"] == nil else { return }
            print("\u{001B}[31mred")
        }
        """#
        #expect(findings(source).isEmpty)
    }
}
