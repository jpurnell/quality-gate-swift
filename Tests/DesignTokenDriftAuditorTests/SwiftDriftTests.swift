import Foundation
import Testing
import QualityGateCore
@testable import DesignTokenDriftAuditor

/// Every fixture is a literal. The "fires" tables and the "quiet" tables are paired on purpose: a
/// checker that finds nothing passes every quiet test, so each rule also has to fire on the
/// spelling its quiet neighbour differs from.
@Suite("SwiftDrift")
struct SwiftDriftTests {

    private func hits(_ source: String, tokens: TokenSet = TokenSet()) -> [String] {
        TokenFixtures.hits(SwiftDrift.analyze(source: source, fileName: "View.swift", tokens: tokens))
    }

    // MARK: hex-colour

    @Test("Hex colour spellings fire", arguments: [
        ##"let c = Color(hex: "#E77500")"##,
        #"let c = Color(hex: "E77500")"#,
        "let c = Color(hex: 0xE77500)",
        "let c = RGB(rgb: 0xFF8D28)",
        ##"let accentValue = "#FF8D28""##,
        "let tint = 0xE77500",
        ##"let c = Color(hex: "#FFF")"##,
        ##"let s = "#FF8D28CC""##,
        #"let c = Color(hexString: "ABCDEF")"#,
        "var fillColor: UInt32 = 0xFF8D28",
    ])
    func hexFires(source: String) {
        #expect(hits(source) == ["design-token.hex-colour:1"], "\(source)")
    }

    @Test("Hex-shaped values that are not colours stay quiet", arguments: [
        "let mask = 0xFFFFFF",
        "let flags = 0xDEADBEEF",
        "let color = 0x12",
        ##"let x = "#include""##,
        ##"let ticket = "#123""##,
        ##"let t = "#1234""##,
        #"let s = "ABCDEF""#,
        "let c = Color(hex: someValue)",
        "let c = Color(hex: hexFromTheme)",
        #"let url = "https://example.com/#section""#,
    ])
    func hexQuiet(source: String) {
        #expect(hits(source) == [], "\(source)")
    }

    // MARK: rgb-initialiser

    @Test("RGB, white and HSB initialisers with a literal component fire", arguments: [
        "let c = Color(red: 1, green: 0.55, blue: 0.16)",
        "let c = Color(.sRGB, red: 0.1, green: 0.2, blue: 0.3, opacity: 1)",
        "let c = UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)",
        "let c = NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)",
        "let c = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)",
        "let c = CGColor(red: 1, green: 0, blue: 0, alpha: 1)",
        "let c = Color(white: 0.5)",
        "let c = UIColor(hue: 0.1, saturation: 0.2, brightness: 0.3, alpha: 1)",
        "let c: Color = .init(red: 0.1, green: 0.2, blue: 0.3)",
        "let c = Color(red: r, green: 0.5, blue: b)",
    ])
    func rgbFires(source: String) {
        #expect(hits(source) == ["design-token.rgb-initialiser:1"], "\(source)")
    }

    @Test("Computed colour maths and system or asset colours stay quiet", arguments: [
        "let c = Color(red: r, green: g, blue: b)",
        "let c = Color(white: w)",
        "let c: Color = .init(red: r, green: g, blue: b)",
        #"let c = Color("Brand")"#,
        #"let c = Color(named: "Brand")"#,
        "let c = Color.accentColor",
        "let c = UIColor.systemOrange",
        "let c = NSColor.labelColor",
    ])
    func rgbQuiet(source: String) {
        #expect(hits(source) == [], "\(source)")
    }

    // MARK: font

    @Test("Fixed-size and custom fonts fire", arguments: [
        #"Text("x").font(.system(size: 14))"#,
        "let f = Font.system(size: 14, weight: .bold)",
        #"let f = Font.custom("Helvetica", size: 12)"#,
        #"Text("x").font(.custom("Avenir", size: 12))"#,
        #"let f = Font.custom("Avenir", fixedSize: 12)"#,
        "let f = UIFont.systemFont(ofSize: 12)",
        "let f = NSFont.systemFont(ofSize: 12, weight: .bold)",
        "let f = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)",
        #"let f = NSFont(name: "Menlo", size: 12)"#,
        #"let f = UIFont(name: "Menlo", size: 12)"#,
        #"Text("x").font(.system(size: size))"#,
    ])
    func fontFires(source: String) {
        #expect(hits(source) == ["design-token.font:1"], "\(source)")
    }

    @Test("Text styles and look-alike enum cases stay quiet", arguments: [
        #"Text("x").font(.system(.body))"#,
        #"Text("x").font(.system(.body, design: .rounded))"#,
        #"Text("x").font(.headline)"#,
        "enum Mode { case custom(Int) }",
        "let m = Mode.custom(3)",
        #"let m: Mode = .custom("x")"#,
    ])
    func fontQuiet(source: String) {
        #expect(hits(source) == [], "\(source)")
    }

    // MARK: corner-radius

    @Test("Literal radii fire", arguments: [
        "Rectangle().cornerRadius(8)",
        "RoundedRectangle(cornerRadius: 8)",
        "RoundedRectangle(cornerRadius: 4, style: .continuous)",
        "Rectangle().clipShape(.rect(cornerRadius: 6))",
        "view.layer.cornerRadius = 8",
        "Rectangle().cornerRadius(0)",
        "Rectangle().cornerRadius(8.5)",
    ])
    func radiusFires(source: String) {
        #expect(hits(source) == ["design-token.corner-radius:1"], "\(source)")
    }

    @Test("Token and computed radii stay quiet", arguments: [
        "Rectangle().cornerRadius(Radius.control)",
        "RoundedRectangle(cornerRadius: r)",
        "view.layer.cornerRadius = theme.radius",
        "view.layer.cornerRadius = r",
    ])
    func radiusQuiet(source: String) {
        #expect(hits(source) == [], "\(source)")
    }

    // MARK: positions and severity

    @Test("A file mixing violations and compliant lines reports exactly the violations, at their lines")
    func mixedFile() {
        let source = """
        import SwiftUI

        struct Card: View {
            var body: some View {
                Text("Hello")
                    .font(.headline)
                    .foregroundStyle(Color(hex: "#E77500"))
                    .background(RoundedRectangle(cornerRadius: 8))
                    .padding(Spacing.unit)
                    .overlay(Color.accentColor)
                    .font(.system(size: 14))
            }
        }
        """
        #expect(hits(source) == [
            "design-token.hex-colour:7",
            "design-token.corner-radius:8",
            "design-token.font:11",
        ])
        let diagnostics = SwiftDrift.analyze(source: source, fileName: "Card.swift", tokens: TokenSet())
        #expect(diagnostics.allSatisfy { $0.severity == .error && $0.filePath == "Card.swift" })
    }

    @Test("Hex-shaped text in a comment or a doc comment is not code")
    func comments() {
        let source = """
        // The accent was #E77500 before the migration.
        /// Use `Color(hex: "#E77500")` never.
        let ok = 1
        """
        #expect(hits(source) == [])
    }

    // MARK: the token each finding names

    @Test("A colour finding names the nearest role and the distance when a token set is configured")
    func nearestColourNamed() throws {
        let diagnostics = SwiftDrift.analyze(
            source: ##"let c = Color(hex: "#E77500")"##, fileName: "V.swift", tokens: TokenFixtures.tokens)
        let fix = try #require(diagnostics.first?.suggestedFix)
        #expect(fix.contains("`accent`"))
        #expect(fix.contains("#FF8D28"))
        #expect(fix.contains("distance 52"))
    }

    @Test("An exact match says so")
    func exactColour() throws {
        let diagnostics = SwiftDrift.analyze(
            source: "let c = RGB(rgb: 0xFF8D28)", fileName: "V.swift", tokens: TokenFixtures.tokens)
        let fix = try #require(diagnostics.first?.suggestedFix)
        #expect(fix.contains("`accent`"))
        #expect(fix.contains("equals"))
    }

    @Test("RGB initialiser components are read as 0...1: (1.0, 0.553, 0.157) is accent within a unit")
    func rgbInitialiserNearest() throws {
        let diagnostics = SwiftDrift.analyze(
            source: "let c = Color(red: 1.0, green: 0.553, blue: 0.157)", fileName: "V.swift", tokens: TokenFixtures.tokens)
        let fix = try #require(diagnostics.first?.suggestedFix)
        #expect(fix.contains("`accent`"))
    }

    @Test("Without a token set the fix names the family and no specific token")
    func noTokensNoNearest() throws {
        let diagnostics = SwiftDrift.analyze(
            source: ##"let c = Color(hex: "#E77500")"##, fileName: "V.swift", tokens: TokenSet())
        let fix = try #require(diagnostics.first?.suggestedFix)
        #expect(fix.contains("colour role"))
        #expect(!fix.contains("accent"))
    }

    @Test("A font finding names the nearest type role", arguments: [
        ("Text(\"x\").font(.system(size: 14))", "`caption`"),
        ("Text(\"x\").font(.system(size: 16))", "`body`"),
        ("Text(\"x\").font(.system(size: 30))", "`heading`"),
        ("let f = UIFont.systemFont(ofSize: 11)", "`label`"),
    ])
    func nearestTypeNamed(source: String, role: String) throws {
        let diagnostics = SwiftDrift.analyze(source: source, fileName: "V.swift", tokens: TokenFixtures.tokens)
        let fix = try #require(diagnostics.first?.suggestedFix)
        #expect(fix.contains(role), "\(fix)")
    }

    @Test("A radius finding names container or control", arguments: [
        ("Rectangle().cornerRadius(8)", "`control`"),
        ("Rectangle().cornerRadius(0)", "`container`"),
        ("view.layer.cornerRadius = 4", "`control`"),
    ])
    func nearestRadiusNamed(source: String, role: String) throws {
        let diagnostics = SwiftDrift.analyze(source: source, fileName: "V.swift", tokens: TokenFixtures.tokens)
        let fix = try #require(diagnostics.first?.suggestedFix)
        #expect(fix.contains(role), "\(fix)")
    }

    // MARK: palette detection

    @Test("definesColour: a file with a colour definition is a palette, one without is not", arguments: [
        (##"enum WinePalette { static let red = Color(hex: "#722F37") }"##, true),
        ("let c = UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)", true),
        ("let c = RGB(rgb: 0xFF8D28)", true),
        ("enum WinePalette { static let red = Color.red }", false),
        ("", false),
        ("let c = Color(red: r, green: g, blue: b)", false),
    ])
    func definesColour(source: String, expected: Bool) {
        #expect(SwiftDrift.definesColour(source: source) == expected, "\(source)")
    }
}
