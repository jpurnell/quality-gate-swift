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
        let source = """
        import SwiftCLIKit

        func highlight() -> String {
            return "\\u{001B}[38;2;255;165;0m"
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

    // MARK: - Checker metadata

    @Test("Checker has correct id and name")
    func metadata() {
        #expect(auditor.id == "accessibility")
        #expect(auditor.name == "Accessibility Auditor")
    }
}
