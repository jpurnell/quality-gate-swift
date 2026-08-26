import Testing
@testable import AccessibilityAuditor

@Suite("AccessibilityAuditor")
struct AccessibilityAuditorTests {
    let auditor = AccessibilityAuditor()

    @Test("Clean code passes with no diagnostics")
    func cleanCode() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hello")
                    .font(.body)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Clean.swift")
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - fixed-font-size

    @Test("Fixed font size triggers warning")
    func fixedFontSize() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hello")
                    .font(.system(size: 14))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "FixedFont.swift")
        let fixedFont = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.fixed-font-size" }
        #expect(fixedFont.count == 1)
        #expect(fixedFont.first?.severity == .warning)
        #expect(fixedFont.first?.suggestedFix?.contains("semantic text style") == true)
    }

    @Test("Semantic font style passes")
    func semanticFontStyle() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hello").font(.headline)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "SemanticFont.swift")
        let fixedFont = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.fixed-font-size" }
        #expect(fixedFont.isEmpty)
    }

    @Test("Diagnostics cite their Apple HIG basis")
    func diagnosticsCiteHIG() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hello").font(.system(size: 14))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Cite.swift")
        let fixedFont = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.fixed-font-size" }
        #expect(fixedFont.first?.message.contains("Apple HIG") == true)
        #expect(fixedFont.first?.message.contains("Dynamic Type") == true)
    }

    // MARK: - missing-reduce-motion

    @Test("withAnimation without reduceMotion triggers warning")
    func withAnimationMissingReduceMotion() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            @State var show = false
            var body: some View {
                Button("Toggle") {
                    withAnimation {
                        show.toggle()
                    }
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Animation.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.count >= 1)
        #expect(motion.first?.suggestedFix?.contains("accessibilityReduceMotion") == true)
    }

    @Test("withAnimation with nearby reduceMotion check passes")
    func withAnimationWithReduceMotion() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            @State var show = false
            @Environment(\\.accessibilityReduceMotion) var reduceMotion
            var body: some View {
                Button("Toggle") {
                    withAnimation(reduceMotion ? nil : .default) {
                        show.toggle()
                    }
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "AnimationOK.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.isEmpty)
    }

    @Test(".animation() modifier without reduceMotion triggers warning")
    func animationModifierMissingReduceMotion() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            @State var offset: CGFloat = 0
            var body: some View {
                Rectangle()
                    .animation(.easeInOut, value: offset)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "AnimMod.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.count >= 1)
    }

    // MARK: - missing-accessibility-label

    @Test("Image without accessibilityLabel triggers warning")
    func imageMissingLabel() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Image(systemName: "star.fill")
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Image.swift")
        let labels = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-accessibility-label" }
        #expect(labels.count == 1)
        #expect(labels.first?.suggestedFix?.contains("accessibilityLabel") == true)
    }

    @Test("Image with accessibilityLabel passes")
    func imageWithLabel() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Image(systemName: "star.fill")
                    .accessibilityLabel("Favorite")
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "ImageOK.swift")
        let labels = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-accessibility-label" }
        #expect(labels.isEmpty)
    }

    @Test("Decorative image with accessibilityHidden passes")
    func decorativeImage() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Image("background")
                    .accessibilityHidden(true)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Decorative.swift")
        let labels = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-accessibility-label" }
        #expect(labels.isEmpty)
    }

    // MARK: - Exemptions

    @Test("SAFETY: comment exempts a line")
    func safetyExemption() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                // SAFETY: this is a fixed layout element
                Text("X").font(.system(size: 8))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Exempt.swift")
        let fixedFont = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.fixed-font-size" }
        #expect(fixedFont.isEmpty)
    }

    // MARK: - missing-reduce-motion: what is not a view animation
    //
    // The rule matched every member access named `animation`. Two of those are not
    // the view modifier at all, and "fixing" them makes the code worse: a
    // TimelineView schedule is a render clock, and `.animation(.none)` already
    // opts out.

    @Test("TimelineView(.animation:) is a render clock, not a view animation")
    func timelineViewScheduleIsNotFlagged() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                    Color.clear
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Clock.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.isEmpty, "TimelineViewSchedule.animation drives a refresh rate; gating it on Reduce Motion would stop the view updating")
    }

    @Test(".animation(.none, ...) already opts out of animating")
    func animationNoneIsNotFlagged() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi")
                    .animation(.none, value: 0)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "AnimNone.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.isEmpty, "`.none` is already the reduced-motion outcome")
    }

    @Test("A real .animation() modifier is still flagged")
    func realAnimationModifierStillFlagged() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            @State var value: Double = 0
            var body: some View {
                Color.black
                    .opacity(value)
                    .animation(.easeInOut(duration: 1.0), value: value)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "RealAnim.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.count >= 1, "A chained modifier has a base expression and must still be caught")
    }

    // MARK: - hardcoded-color: dynamic arguments are not hardcoded

    @Test("Color(hex:) with a runtime argument is not a hardcoded colour")
    func dynamicHexColorIsNotFlagged() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            let modeColorHex: String
            var body: some View {
                Circle().fill(Color(hex: modeColorHex))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "DynHex.swift")
        let hard = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.hardcoded-color-string" }
        #expect(hard.isEmpty, "The value comes from a property at runtime; there is no literal to replace")
    }

    @Test("A literal Color(hex:) is still flagged")
    func literalHexColorStillFlagged() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Circle().fill(Color(hex: "#FF0000"))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "LitHex.swift")
        let hard = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.hardcoded-color-string" }
        #expect(hard.count >= 1, "A literal hex string is exactly what this rule is for")
    }

    // MARK: - color-only: a non-colour companion in the same chain

    @Test("A state-varying .opacity counts as a non-colour companion")
    func opacityCompanionIsNotFlagged() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            let isConnected: Bool
            var body: some View {
                Image(systemName: "eyeglasses")
                    .foregroundStyle(isConnected ? Color.secondary : Color.orange)
                    .opacity(isConnected ? 0.5 : 1)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Companion.swift")
        let colorOnly = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.color-only-differentiation" }
        #expect(colorOnly.isEmpty, "Opacity varies with the same condition, so colour is not the sole signal")
    }

    @Test("Colour alone with no companion is still flagged")
    func colorAloneStillFlagged() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            let isOn: Bool
            var body: some View {
                Text("Status")
                    .foregroundStyle(isOn ? Color.green : Color.red)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "ColorAlone.swift")
        let colorOnly = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.color-only-differentiation" }
        #expect(colorOnly.count >= 1, "Nothing but the colour changes here")
    }

    // MARK: - Scope-Aware reduceMotion Check

    @Test("Scope-aware check finds reduceMotion distant in same function body")
    func scopeAwareFindsDistantCheck() async throws {
        let padding = (0..<20).map { _ in "            let x = 1" }.joined(separator: "\n")
        let source = """
        import SwiftUI

        struct MyView: View {
            @Environment(\\.accessibilityReduceMotion) var reduceMotion
            var body: some View {
                let _ = reduceMotion
        \(padding)
                withAnimation {
                    show.toggle()
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "ScopeAware.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.isEmpty, "Scope-aware check should find reduceMotion in the same body closure")
    }

    @Test("Flags animation when reduceMotion is in a different function")
    func differentScopeStillFlags() async throws {
        let padding = (0..<20).map { _ in "        let x = 1" }.joined(separator: "\n")
        let source = """
        import SwiftUI

        struct MyView: View {
            @State var show = false
            func setup() {
                if reduceMotion { return }
            }
        \(padding)
            func animate() {
                withAnimation {
                    show.toggle()
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "DiffScope.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.count >= 1, "Should flag animation when reduceMotion is in a different function scope")
    }

    @Test("Existing radius fast-path still works for nearby reduceMotion")
    func radiusFastPathStillWorks() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            @State var show = false
            @Environment(\\.accessibilityReduceMotion) var reduceMotion
            var body: some View {
                Button("Toggle") {
                    withAnimation(reduceMotion ? nil : .default) {
                        show.toggle()
                    }
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "RadiusFast.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.isEmpty, "Fast-path radius check should still find nearby reduceMotion")
    }

    @Test(".animation() modifier with scope-aware reduceMotion check")
    func animationModifierScopeAware() async throws {
        let padding = (0..<20).map { _ in "            let x = 1" }.joined(separator: "\n")
        let source = """
        import SwiftUI

        struct MyView: View {
            @Environment(\\.accessibilityReduceMotion) var reduceMotion
            var body: some View {
                let _ = reduceMotion
        \(padding)
                Rectangle()
                    .animation(.easeInOut, value: offset)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "AnimModScope.swift")
        let motion = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-reduce-motion" }
        #expect(motion.isEmpty, "Scope-aware check should find reduceMotion for .animation() modifier too")
    }

    // MARK: - CLI: no-color-not-respected

    @Test("ANSI color without a color-preference guard triggers warning")
    func cliAnsiColorUnguarded() async throws {
        let source = """
        import ArgumentParser

        func printError() {
            print("\\u{001B}[31mError\\u{001B}[0m")
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Colors.swift")
        let color = result.diagnostics.filter { $0.ruleId == "a11y.cli.no-color-not-respected" }
        #expect(color.count == 1)
        #expect(color.first?.message.contains("NO_COLOR") == true)
    }

    @Test("Truecolor ANSI (38;2;r;g;b) without a guard triggers warning")
    func cliTruecolorUnguarded() async throws {
        // Printed rather than returned: the rule is about output, and a function handing a
        // string back to its caller emits nothing. What this test is pinning is that the
        // truecolor SGR form is recognised as color, which the print form still exercises.
        let source = """
        import SwiftCLIKit

        func highlight() {
            print("\\u{001B}[38;2;255;165;0m")
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Truecolor.swift")
        let color = result.diagnostics.filter { $0.ruleId == "a11y.cli.no-color-not-respected" }
        #expect(color.count == 1)
    }

    @Test("ANSI color with a NO_COLOR guard passes")
    func cliAnsiColorGuarded() async throws {
        let source = """
        import ArgumentParser
        import Foundation

        func printError() {
            if ProcessInfo.processInfo.environment["NO_COLOR"] == nil {
                print("\\u{001B}[31mError\\u{001B}[0m")
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Guarded.swift")
        let color = result.diagnostics.filter { $0.ruleId == "a11y.cli.no-color-not-respected" }
        #expect(color.isEmpty)
    }

    @Test("Cursor-control ANSI without color is not flagged")
    func cliCursorControlOnly() async throws {
        let source = """
        import ArgumentParser

        func clearScreen() {
            print("\\u{001B}[2J")
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Clear.swift")
        let color = result.diagnostics.filter { $0.ruleId == "a11y.cli.no-color-not-respected" }
        #expect(color.isEmpty)
    }

    @Test("Colored interpolation with no text (color-only meaning) triggers warning")
    func cliColorOnlyMeaning() async throws {
        let source = """
        import SwiftCLIKit

        func report(_ status: String) {
            print("\\u{001B}[31m\\(status)\\u{001B}[0m")
        }
        """
        let result = try await auditor.auditSource(source, fileName: "ColorOnly.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.cli.color-only-meaning" }
        #expect(hits.count == 1)
    }

    @Test("Colored output with a text marker is not color-only")
    func cliColoredWithText() async throws {
        let source = """
        import SwiftCLIKit

        func report(_ status: String) {
            print("\\u{001B}[31merror: \\(status)\\u{001B}[0m")
        }
        """
        let result = try await auditor.auditSource(source, fileName: "ColoredText.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.cli.color-only-meaning" }
        #expect(hits.isEmpty)
    }

    @Test("Cursor/screen control without a terminal check triggers warning")
    func cliCursorControlNoTty() async throws {
        let source = """
        import SwiftCLIKit

        func clearScreen() {
            print("\\u{001B}[2J")
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Cursor.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.cli.cursor-control-no-tty" }
        #expect(hits.count == 1)
    }

    @Test("Cursor control with an isatty guard passes")
    func cliCursorControlGuarded() async throws {
        let source = """
        import SwiftCLIKit
        import Foundation

        func clearScreen() {
            if isatty(STDOUT_FILENO) != 0 {
                print("\\u{001B}[2J")
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "CursorOK.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.cli.cursor-control-no-tty" }
        #expect(hits.isEmpty)
    }

    @Test("Non-frontend file (no CLI/SwiftUI import) is not scanned for CLI color")
    func cliNonFrontendSkipped() async throws {
        let source = """
        import Foundation

        func p() { print("\\u{001B}[31mx\\u{001B}[0m") }
        """
        let result = try await auditor.auditSource(source, fileName: "Plain.swift")
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - A-1: custom-font-no-relativeto

    @Test("Custom font with fixed size (no relativeTo) triggers warning")
    func customFontNoRelativeTo() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi").font(.custom("Inter", size: 15))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "CustomFont.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.custom-font-no-relativeto" }
        #expect(hits.count == 1)
        #expect(hits.first?.message.contains("Dynamic Type") == true)
    }

    @Test("Custom font with relativeTo passes")
    func customFontWithRelativeTo() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi").font(.custom("Inter", size: 15, relativeTo: .body))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "CustomFontOK.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.custom-font-no-relativeto" }
        #expect(hits.isEmpty)
    }

    @Test("Custom font with explicit fixedSize is intentional and passes")
    func customFontFixedSize() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi").font(.custom("Inter", fixedSize: 15))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "FixedSize.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.custom-font-no-relativeto" }
        #expect(hits.isEmpty)
    }

    // MARK: - A-2: tap-gesture-missing-button-trait

    @Test("onTapGesture without a button trait triggers warning")
    func tapGestureMissingButtonTrait() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Tap me").onTapGesture { }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Tap.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.tap-gesture-missing-button-trait" }
        #expect(hits.count == 1)
        #expect(hits.first?.message.contains("VoiceOver") == true)
    }

    @Test("onTapGesture with accessibilityAddTraits(.isButton) passes")
    func tapGestureWithButtonTrait() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Tap me")
                    .onTapGesture { }
                    .accessibilityAddTraits(.isButton)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "TapOK.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.tap-gesture-missing-button-trait" }
        #expect(hits.isEmpty)
    }

    @Test("onTapGesture with a named accessibilityAction passes")
    func tapGestureWithAccessibilityAction() async throws {
        // A named action is the API Apple's guidance points at for a gesture with no visible
        // control, and on a container it is the *better* answer: `.isButton` on a scrollable
        // map makes VoiceOver announce the whole map as one button.
        let source = """
        import SwiftUI

        struct MapView: View {
            var body: some View {
                MapContainer()
                    .onTapGesture(count: 2) { }
                    .accessibilityAction(named: "Reset zoom") { }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "TapAction.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.tap-gesture-missing-button-trait" }
        #expect(hits.isEmpty)
    }

    @Test("A multi-tap gesture is an accelerator, not a control, so it is not flagged")
    func multiTapGestureIsNotAControl() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Zoom").onTapGesture(count: 2) { }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "DoubleTap.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.tap-gesture-missing-button-trait" }
        #expect(hits.isEmpty)
    }

    @Test("An explicit single-tap gesture still warns")
    func explicitSingleTapStillWarns() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Tap me").onTapGesture(count: 1) { }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "SingleTap.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.tap-gesture-missing-button-trait" }
        #expect(hits.count == 1)
    }

    // MARK: - hardcoded-color-string

    @Test("Hardcoded RGB Color triggers warning")
    func hardcodedRGBColor() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi").background(Color(red: 0.1, green: 0.2, blue: 0.3))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "RGB.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.hardcoded-color-string" }
        #expect(hits.count == 1)
    }

    @Test("Hardcoded white Color triggers warning")
    func hardcodedWhiteColor() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi").foregroundColor(Color(white: 0.9))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "White.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.hardcoded-color-string" }
        #expect(hits.count == 1)
    }

    @Test("Asset-catalog and system colors pass")
    func adaptiveColorsPass() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi")
                    .background(Color("Brand"))
                    .foregroundColor(Color(.systemBackground))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Adaptive.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.hardcoded-color-string" }
        #expect(hits.isEmpty)
    }

    // MARK: - color-only-differentiation

    @Test("Condition-selected color with no differentiator triggers warning")
    func colorOnlyState() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            let isError = true
            var body: some View {
                Text("Status").foregroundColor(isError ? .red : .green)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "ColorOnly.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.color-only-differentiation" }
        #expect(hits.count == 1)
    }

    @Test("Color state with a Differentiate-Without-Color guard passes")
    func colorStateWithGuard() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            let isError = true
            @Environment(\\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor
            var body: some View {
                Text("Status").foregroundColor(isError ? .red : .green)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "ColorGuard.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.color-only-differentiation" }
        #expect(hits.isEmpty)
    }

    // MARK: - missing-accessibility-hint

    @Test("Labeled custom tap control without a hint triggers warning")
    func missingHint() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Play")
                    .onTapGesture { }
                    .accessibilityLabel("Play")
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Hint.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-accessibility-hint" }
        #expect(hits.count == 1)
    }

    @Test("Labeled custom control with a hint passes")
    func hintPresent() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Play")
                    .onTapGesture { }
                    .accessibilityLabel("Play")
                    .accessibilityHint("Plays the track")
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "HintOK.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-accessibility-hint" }
        #expect(hits.isEmpty)
    }

    // MARK: - A-3: decorative-image-not-hidden

    @Test("Decorative background image without hidden triggers warning (not the label rule)")
    func decorativeImageNotHidden() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi").background(Image("texture"))
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Decor.swift")
        let decorative = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.decorative-image-not-hidden" }
        let label = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.missing-accessibility-label" }
        #expect(decorative.count == 1)
        #expect(label.isEmpty, "decorative image should not also trip the label rule")
    }

    @Test("Decorative image with accessibilityHidden passes")
    func decorativeImageHidden() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi").background(Image("texture")).accessibilityHidden(true)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "DecorOK.swift")
        let decorative = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.decorative-image-not-hidden" }
        #expect(decorative.isEmpty)
    }

    // MARK: - A-4: material-no-reduce-transparency

    @Test("Material without a Reduce Transparency guard triggers warning")
    func materialNoReduceTransparency() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Text("Hi").background(.ultraThinMaterial)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Material.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.material-no-reduce-transparency" }
        #expect(hits.count == 1)
    }

    @Test("Material with a Reduce Transparency guard passes")
    func materialWithGuard() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            @Environment(\\.accessibilityReduceTransparency) var reduceTransparency
            var body: some View {
                Text("Hi").background(.ultraThinMaterial)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "MaterialOK.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.material-no-reduce-transparency" }
        #expect(hits.isEmpty)
    }

    // MARK: - A-5: standard-shortcut-override

    @Test("Command + reserved key shortcut triggers warning")
    func standardShortcutOverride() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Button("Copy") { }.keyboardShortcut("c", modifiers: .command)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Shortcut.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.standard-shortcut-override" }
        #expect(hits.count == 1)
    }

    @Test("Non-reserved key and multi-modifier combos pass")
    func nonReservedShortcut() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Button("K") { }.keyboardShortcut("k", modifiers: .command)
                Button("Shift-C") { }.keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "ShortcutOK.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.standard-shortcut-override" }
        #expect(hits.isEmpty)
    }

    @Test("Command-N inside CommandGroup(replacing: .newItem) is the standard binding, not an override")
    func standardShortcutInMatchingCommandGroup() async throws {
        // The rule's own `suggestedFix` asks for exactly this shape. Flagging it told an
        // author to fix code that was already fixed, and the only literal way to comply —
        // deleting the modifier — silently removes Command-N from the app, because
        // `CommandGroup(replacing:)` does not confer the placement's shortcut on a custom
        // Button. Verified against a real `NSApp.mainMenu` dump, not assumed.
        let source = """
        import SwiftUI

        struct GameCommands: Commands {
            var body: some Commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Game") { }
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Commands.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.standard-shortcut-override" }
        #expect(hits.isEmpty)
    }

    @Test("`before:` and `after:` placements count the same as `replacing:`")
    func standardShortcutInAdjacentCommandGroup() async throws {
        let source = """
        import SwiftUI

        struct GameCommands: Commands {
            var body: some Commands {
                CommandGroup(before: .newItem) {
                    Button("New Game") { }
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "CommandsBefore.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.standard-shortcut-override" }
        #expect(hits.isEmpty)
    }

    @Test("A key that does not match its placement still warns")
    func mismatchedKeyInCommandGroupStillWarns() async throws {
        // `.saveItem` is Command-S. Binding Command-N there is a repurposing, and the
        // enclosing placement is what makes it one.
        let source = """
        import SwiftUI

        struct GameCommands: Commands {
            var body: some Commands {
                CommandGroup(replacing: .saveItem) {
                    Button("New Game") { }
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "CommandsMismatch.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.standard-shortcut-override" }
        #expect(hits.count == 1)
    }

    @Test("A custom CommandMenu is not a standard placement, so it still warns")
    func customCommandMenuStillWarns() async throws {
        let source = """
        import SwiftUI

        struct GameCommands: Commands {
            var body: some Commands {
                CommandMenu("Game") {
                    Button("New Game") { }
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "CommandMenu.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.standard-shortcut-override" }
        #expect(hits.count == 1)
    }

    // MARK: - A-6: hit-target-too-small

    @Test("Button with a sub-44pt frame triggers warning")
    func hitTargetTooSmall() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Button("x") { }.frame(width: 20, height: 20)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "Hit.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.hit-target-too-small" }
        #expect(hits.count == 1)
    }

    @Test("44pt frame, padded button, and non-button frames pass")
    func hitTargetOK() async throws {
        let source = """
        import SwiftUI

        struct MyView: View {
            var body: some View {
                Button("a") { }.frame(width: 44, height: 44)
                Button("b") { }.padding().frame(width: 20, height: 20)
                Text("c").frame(width: 10, height: 10)
            }
        }
        """
        let result = try await auditor.auditSource(source, fileName: "HitOK.swift")
        let hits = result.diagnostics.filter { $0.ruleId == "a11y.swiftui.hit-target-too-small" }
        #expect(hits.isEmpty)
    }

    // MARK: - Checker metadata

    @Test("Checker has correct id and name")
    func metadata() {
        #expect(auditor.id == "accessibility")
        #expect(auditor.name == "Accessibility Auditor")
    }
}
