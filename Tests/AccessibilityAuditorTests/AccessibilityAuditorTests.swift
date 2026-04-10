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
        let fixedFont = result.diagnostics.filter { $0.ruleId == "fixed-font-size" }
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
        let fixedFont = result.diagnostics.filter { $0.ruleId == "fixed-font-size" }
        #expect(fixedFont.isEmpty)
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
        let motion = result.diagnostics.filter { $0.ruleId == "missing-reduce-motion" }
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
        let motion = result.diagnostics.filter { $0.ruleId == "missing-reduce-motion" }
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
        let motion = result.diagnostics.filter { $0.ruleId == "missing-reduce-motion" }
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
        let labels = result.diagnostics.filter { $0.ruleId == "missing-accessibility-label" }
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
        let labels = result.diagnostics.filter { $0.ruleId == "missing-accessibility-label" }
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
        let labels = result.diagnostics.filter { $0.ruleId == "missing-accessibility-label" }
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
        let fixedFont = result.diagnostics.filter { $0.ruleId == "fixed-font-size" }
        #expect(fixedFont.isEmpty)
    }

    // MARK: - Checker metadata

    @Test("Checker has correct id and name")
    func metadata() {
        #expect(auditor.id == "accessibility")
        #expect(auditor.name == "Accessibility Auditor")
    }
}
