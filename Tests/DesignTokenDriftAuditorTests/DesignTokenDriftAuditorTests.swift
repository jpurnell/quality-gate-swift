import Foundation
import Testing
import QualityGateCore
@testable import DesignTokenDriftAuditor

/// The whole `check(configuration:)` path on a real directory, with the real exemption
/// mechanism in play. These are the seeded-violation tests: each one fails if the rule it names
/// stops firing, and each has a quiet twin so that firing is not simply everything firing.
@Suite("DesignTokenDriftAuditor — whole run")
struct DesignTokenDriftAuditorTests {

    private static let violation = ##"let c = Color(hex: "#E77500")"##
    /// The DesignTokens 0.8.0 marker shape: one AppPaletteSource conformer, one AppPalette(id: "literal").
    private static func markedPalette(name: String = "WinePalette", id: String = "winetaster") -> String {
        """
        import DesignTokens
        enum \(name): AppPaletteSource {
            static let palette = AppPalette(id: "\(id)", accent: Adaptive(light: 0x7F0017))
            static let wine = Color(hex: "#722F37")
        }
        """
    }
    private static let palette = markedPalette()
    private static let paletteTest = "func t() { #expect(WinePalette.validate().isConformant) }"

    private func run(_ files: [String: String], _ config: DesignTokensConfig) async throws -> CheckResult {
        let project = try DriftProject(files: files)
        defer { project.remove() }
        return try await DesignTokenDriftAuditor().check(configuration: project.configuration(config))
    }

    private func rules(_ result: CheckResult) -> [String] { result.diagnostics.compactMap(\.ruleId) }

    @Test("Not enabled: skipped, and nothing read")
    func notEnabled() async throws {
        let result = try await run(["A.swift": Self.violation], DesignTokensConfig())
        #expect(result.status == .skipped)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Enabled: a seeded hex colour fails the run, with path and line")
    func seededFires() async throws {
        let result = try await run(["Sources/A.swift": "import SwiftUI\n" + Self.violation + "\n"], DesignTokensConfig(enabled: true))
        #expect(result.status == .failed)
        let finding = try #require(result.diagnostics.first { $0.ruleId == "design-token.hex-colour" })
        #expect(finding.lineNumber == 2)
        #expect(finding.filePath?.hasSuffix("Sources/A.swift") == true)
    }

    @Test("Enabled: correct code passes, and the run says what it read")
    func correctCodeQuiet() async throws {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View { Text("x").font(.headline).foregroundStyle(Color.accentColor) }
        }
        """
        let result = try await run(["Sources/V.swift": source], DesignTokensConfig(enabled: true))
        #expect(result.status == .passed)
        #expect(rules(result) == ["design-token.coverage"])
        let note = try #require(result.diagnostics.first)
        #expect(note.severity == .note)
        #expect(note.message.contains("1 Swift file"))
    }

    @Test("A declared palette file is quiet; an undeclared sibling with the same literal fires")
    func declaredPalette() async throws {
        let config = DesignTokensConfig(enabled: true, exemptPaletteFiles: ["Sources/WinePalette.swift"])
        let result = try await run(
            ["Sources/WinePalette.swift": Self.palette, "Sources/Other.swift": Self.palette,
             "Tests/T.swift": Self.paletteTest], config)
        let flagged = result.diagnostics.filter { $0.ruleId == "design-token.hex-colour" }
        #expect(flagged.count == 1)
        #expect(flagged.first?.filePath?.hasSuffix("Sources/Other.swift") == true)
    }

    @Test("A declared palette that no longer exists is an error naming the entry")
    func paletteMissing() async throws {
        let config = DesignTokensConfig(enabled: true, exemptPaletteFiles: ["Sources/GonePalette.swift"])
        let result = try await run(["Sources/A.swift": "let x = 1"], config)
        #expect(result.status == .failed)
        let finding = try #require(result.diagnostics.first { $0.ruleId == "design-token.palette-missing" })
        #expect(finding.severity == .error)
        #expect(finding.message.contains("Sources/GonePalette.swift"))
    }

    @Test("A listed file with colours but no AppPaletteSource marker is an error: listing is not enough")
    func paletteNoMarker() async throws {
        let config = DesignTokensConfig(enabled: true, exemptPaletteFiles: ["Sources/WinePalette.swift"])
        let result = try await run(["Sources/WinePalette.swift": ##"enum WinePalette { static let red = Color(hex: "#722F37") }"##], config)
        #expect(result.status == .failed)
        #expect(rules(result).contains("design-token.palette-no-marker"))
    }

    @Test("A comment is not a marker")
    func commentIsNotAMarker() async throws {
        let source = "// design-tokens: app-palette winetaster\n" + ##"let c = Color(hex: "#722F37")"##
        let config = DesignTokensConfig(enabled: true, exemptPaletteFiles: ["Sources/P.swift"])
        let result = try await run(["Sources/P.swift": source], config)
        #expect(rules(result).contains("design-token.palette-no-marker"))
    }

    @Test("The exemption covers colour literals only: a font and a radius in the palette file still fire")
    func exemptionIsColourOnly() async throws {
        let source = Self.palette + "\nlet f = Font.system(size: 14)\nlet r = RoundedRectangle(cornerRadius: 8)\n"
        let config = DesignTokensConfig(enabled: true, exemptPaletteFiles: ["Sources/WinePalette.swift"])
        let result = try await run(["Sources/WinePalette.swift": source, "Tests/T.swift": Self.paletteTest], config)
        let found = rules(result).filter { $0.hasPrefix("design-token.") && $0 != "design-token.coverage" }
        #expect(found.sorted() == ["design-token.corner-radius", "design-token.font"])
    }

    @Test("Marker shape violations: two conformers, no or two AppPalette calls, a non-literal id")
    func markerShape() async throws {
        let twoConformers = "enum A: AppPaletteSource { static let palette = AppPalette(id: \"a\") }\nstruct B: AppPaletteSource { static let palette = AppPalette(id: \"b\") }"
        let noCall = "enum A: AppPaletteSource { static let palette = make() }"
        let twoCalls = "enum A: AppPaletteSource { static let palette = AppPalette(id: \"a\"); static let other = AppPalette(id: \"b\") }"
        let dynamicID = "enum A: AppPaletteSource { static let palette = AppPalette(id: name) }"
        let expected: [(String, String)] = [
            (twoConformers, "design-token.palette-multiple-markers"),
            (noCall, "design-token.palette-bad-id"),
            (twoCalls, "design-token.palette-bad-id"),
            (dynamicID, "design-token.palette-bad-id"),
        ]
        for (source, rule) in expected {
            let config = DesignTokensConfig(enabled: true, exemptPaletteFiles: ["Sources/P.swift"])
            let result = try await run(["Sources/P.swift": source], config)
            #expect(rules(result).contains(rule), "\(source)")
        }
    }

    @Test("Marker spellings: DesignTokens-qualified, extension, nested and class forms are all recognised", arguments: [
        "enum P: DesignTokens.AppPaletteSource { static let palette = AppPalette(id: \"a\") }",
        "struct P {}\nextension P: AppPaletteSource { static let palette = AppPalette(id: \"a\") }",
        "enum Outer { struct P: Sendable, AppPaletteSource { static let palette = AppPalette(id: \"a\") } }",
        "final class P: AppPaletteSource { static let palette = AppPalette(id: \"a\") }",
        "actor P: AppPaletteSource { static let palette = AppPalette(id: \"a\") }",
    ])
    func markerSpellings(source: String) {
        let marker = SwiftDrift.paletteMarker(source: source)
        #expect(marker.present && marker.isValid && marker.ids == ["a"], "\(source)")
    }

    @Test("Look-alikes are not markers", arguments: [
        "enum P: AppPaletteSourceLike {}",
        "enum P { static let palette = AppPalette(id: \"a\") }",
        "// enum P: AppPaletteSource {}",
        "let s = \"AppPaletteSource\"",
    ])
    func notMarkers(source: String) {
        #expect(!SwiftDrift.paletteMarker(source: source).present, "\(source)")
    }

    @Test("Two declared palettes with one id is an error")
    func duplicateID() async throws {
        let config = DesignTokensConfig(enabled: true, exemptPaletteFiles: ["Sources/*Palette.swift"])
        let result = try await run([
            "Sources/APalette.swift": Self.markedPalette(name: "APalette", id: "same"),
            "Sources/BPalette.swift": Self.markedPalette(name: "BPalette", id: "same"),
            "Tests/T.swift": "APalette.validate().isConformant BPalette.validate().isConformant",
        ], config)
        #expect(rules(result).filter { $0 == "design-token.palette-duplicate-id" }.count == 1)
    }

    @Test("A declared palette no test validates is a warning, not an error; with a test it is quiet")
    func untested() async throws {
        let config = DesignTokensConfig(enabled: true, exemptPaletteFiles: ["Sources/WinePalette.swift"])
        let without = try await run(["Sources/WinePalette.swift": Self.palette], config)
        #expect(without.status == .warning)
        let warning = try #require(without.diagnostics.first { $0.ruleId == "design-token.palette-untested" })
        #expect(warning.severity == .warning)
        let with = try await run(["Sources/WinePalette.swift": Self.palette, "Tests/T.swift": Self.paletteTest], config)
        #expect(with.status == .passed)
    }

    @Test("A marked file that is not declared in config is a note, and its colours still fire")
    func undeclaredMarker() async throws {
        let result = try await run(["Sources/WinePalette.swift": Self.palette], DesignTokensConfig(enabled: true))
        #expect(rules(result).contains("design-token.palette-undeclared"))
        #expect(rules(result).contains("design-token.hex-colour"))
        #expect(result.diagnostics.first { $0.ruleId == "design-token.palette-undeclared" }?.severity == .note)
    }

    @Test("A glob that matches several palette files validates each of them")
    func paletteGlob() async throws {
        let config = DesignTokensConfig(enabled: true, exemptPaletteFiles: ["Sources/**/*Palette.swift"])
        let result = try await run([
            "Sources/A/RedPalette.swift": Self.palette,
            "Sources/B/BluePalette.swift": "enum BluePalette {}",
            "Tests/T.swift": Self.paletteTest,
        ], config)
        let empty = result.diagnostics.filter { $0.ruleId == "design-token.palette-no-marker" }
        #expect(empty.count == 1)
        #expect(empty.first?.filePath?.hasSuffix("Sources/B/BluePalette.swift") == true)
        #expect(!rules(result).contains("design-token.hex-colour"))
    }

    @Test("Test paths are exempt only when listed; the same file outside the list fires")
    func testPaths() async throws {
        let files = ["Tests/ViewTests.swift": Self.violation, "Sources/View.swift": Self.violation]
        let held = try await run(files, DesignTokensConfig(enabled: true))
        #expect(held.diagnostics.filter { $0.ruleId == "design-token.hex-colour" }.count == 2)

        let exempt = try await run(files, DesignTokensConfig(enabled: true, exemptTestPaths: ["Tests/**"]))
        let flagged = exempt.diagnostics.filter { $0.ruleId == "design-token.hex-colour" }
        #expect(flagged.count == 1)
        #expect(flagged.first?.filePath?.hasSuffix("Sources/View.swift") == true)
    }

    @Test("The tokens package path is not read")
    func packagePath() async throws {
        let files = ["Vendor/DesignTokens/Sources/P.swift": Self.palette, "Sources/A.swift": "let x = 1"]
        let result = try await run(files, DesignTokensConfig(enabled: true, exemptPackagePaths: ["Vendor/DesignTokens"]))
        #expect(!rules(result).contains("design-token.hex-colour"))
        #expect(result.status == .passed)
    }

    @Test("Build products and dependency checkouts are not read")
    func buildDirectoriesSkipped() async throws {
        let files = [".build/checkouts/Dep/A.swift": Self.violation, "Pods/P/A.swift": Self.violation,
                     "node_modules/m/a.swift": Self.violation, "Sources/A.swift": "let x = 1"]
        let result = try await run(files, DesignTokensConfig(enabled: true))
        #expect(result.status == .passed)
    }

    // MARK: CSS

    private static let tokensCSS = TokenFixtures.css

    @Test("CSS under cssPaths is checked against the token file; the token file itself is not scanned")
    func cssChecked() async throws {
        let config = DesignTokensConfig(
            enabled: true, cssPaths: ["Assets/css/**"], tokenFiles: ["Assets/css/tokens.css"])
        let result = try await run([
            "Assets/css/tokens.css": Self.tokensCSS,
            "Assets/css/main.css": ".a { color: #E77500; font-size: 14px; }\n",
        ], config)
        #expect(result.status == .failed)
        let found = result.diagnostics.filter { $0.ruleId?.hasPrefix("design-token.css") == true }
        #expect(found.map { $0.ruleId } == ["design-token.css-colour", "design-token.css-font-size"])
        #expect(found.allSatisfy { $0.filePath?.hasSuffix("Assets/css/main.css") == true })
    }

    @Test("CSS outside cssPaths is not read")
    func cssOutsideScope() async throws {
        let config = DesignTokensConfig(
            enabled: true, cssPaths: ["Assets/css/**"], tokenFiles: ["Assets/css/tokens.css"])
        let result = try await run([
            "Assets/css/tokens.css": Self.tokensCSS,
            "vendor/bootstrap.css": ".a { color: #E77500; }\n",
        ], config)
        #expect(result.status == .passed)
    }

    @Test("CSS that uses only tokens passes")
    func cssQuiet() async throws {
        let config = DesignTokensConfig(
            enabled: true, cssPaths: ["Assets/css/**"], tokenFiles: ["Assets/css/tokens.css"])
        let result = try await run([
            "Assets/css/tokens.css": Self.tokensCSS,
            "Assets/css/main.css": ".a { color: var(--accent); font-size: var(--type-body-size); gap: var(--gutter); }\n",
        ], config)
        #expect(result.status == .passed)
    }

    @Test("cssPaths with no token file is a configuration error, not a pass")
    func cssWithoutTokens() async throws {
        let config = DesignTokensConfig(enabled: true, cssPaths: ["Assets/css/**"])
        let result = try await run(["Assets/css/main.css": ".a { margin: 0; }\n"], config)
        #expect(result.status == .failed)
        #expect(rules(result).contains("design-token.config"))
    }

    @Test("A token file glob that matches nothing is a configuration error")
    func tokenFileMissing() async throws {
        let config = DesignTokensConfig(enabled: true, cssPaths: ["Assets/**"], tokenFiles: ["Assets/css/tokens.css"])
        let result = try await run(["Assets/css/main.css": ".a { margin: 0; }\n"], config)
        #expect(result.status == .failed)
        #expect(rules(result).contains("design-token.config"))
    }

    @Test("A token file that yields no tokens is a configuration error")
    func tokenFileEmpty() async throws {
        let config = DesignTokensConfig(enabled: true, cssPaths: ["Assets/**"], tokenFiles: ["Assets/css/tokens.css"])
        let result = try await run(["Assets/css/tokens.css": "/* nothing */", "Assets/css/main.css": ".a{margin:0}"], config)
        #expect(result.status == .failed)
        #expect(rules(result).contains("design-token.config"))
    }

    @Test("A CSS palette file is declared by path and validated like a Swift one")
    func cssPalette() async throws {
        let config = DesignTokensConfig(
            enabled: true, exemptPaletteFiles: ["Assets/css/wine.css", "Assets/css/empty.css"],
            cssPaths: ["Assets/css/**"], tokenFiles: ["Assets/css/tokens.css"])
        let result = try await run([
            "Assets/css/tokens.css": Self.tokensCSS,
            "Assets/css/wine.css": ":root { --wine: #722F37; }\n",
            "Assets/css/empty.css": ".a { margin: 0; }\n",
        ], config)
        #expect(!rules(result).contains("design-token.css-colour"))
        let empty = result.diagnostics.filter { $0.ruleId == "design-token.palette-empty" }
        #expect(empty.count == 1)
        #expect(empty.first?.filePath?.hasSuffix("empty.css") == true)
    }

    @Test("Tokens loaded from the token file name the nearest role in a Swift finding")
    func swiftUsesTokenFile() async throws {
        let config = DesignTokensConfig(enabled: true, cssPaths: ["Assets/**"], tokenFiles: ["Assets/css/tokens.css"])
        let result = try await run(["Assets/css/tokens.css": Self.tokensCSS, "Sources/A.swift": Self.violation], config)
        let finding = try #require(result.diagnostics.first { $0.ruleId == "design-token.hex-colour" })
        #expect(finding.suggestedFix?.contains("`accent`") == true)
    }

    // MARK: determinism

    @Test("Findings come back in a stable order across runs")
    func stableOrder() async throws {
        let files = ["Sources/B.swift": Self.violation, "Sources/A.swift": Self.violation, "Sources/C.swift": Self.violation]
        let project = try DriftProject(files: files)
        defer { project.remove() }
        let config = project.configuration(DesignTokensConfig(enabled: true))
        let first = try await DesignTokenDriftAuditor().check(configuration: config)
        let second = try await DesignTokenDriftAuditor().check(configuration: config)
        #expect(first.diagnostics.map(\.filePath) == second.diagnostics.map(\.filePath))
        let paths = first.diagnostics.compactMap(\.filePath).filter { $0.hasSuffix(".swift") }
        #expect(paths == paths.sorted())
    }
}
