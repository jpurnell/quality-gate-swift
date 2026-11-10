import Testing
import QualityGateCore

@Suite("designTokens configuration")
struct ConfigurationTests {

    @Test("A YAML section decodes every key")
    func decodes() throws {
        let configuration = try Configuration.from(yaml: """
        designTokens:
          enabled: true
          exemptPackagePaths: ["Vendor/DesignTokens"]
          exemptPaletteFiles: ["Sources/WinePalette.swift"]
          exemptTestPaths: ["**/Tests/**"]
          cssPaths: ["Assets/css/**"]
          tokenFiles: ["Assets/css/tokens.css"]
        """)
        #expect(configuration.designTokens == DesignTokensConfig(
            enabled: true,
            exemptPackagePaths: ["Vendor/DesignTokens"],
            exemptPaletteFiles: ["Sources/WinePalette.swift"],
            exemptTestPaths: ["**/Tests/**"],
            cssPaths: ["Assets/css/**"],
            tokenFiles: ["Assets/css/tokens.css"]))
    }

    @Test("Absent section means opted out, with nothing declared")
    func defaultsOptOut() throws {
        let configuration = try Configuration.from(yaml: "excludePatterns: []\n")
        #expect(configuration.designTokens == DesignTokensConfig())
        #expect(!configuration.designTokens.enabled)
    }

    @Test("Every declared exemption is reported as an active exclusion")
    func exclusionsReported() throws {
        let configuration = try Configuration.from(yaml: """
        designTokens:
          enabled: true
          exemptPackagePaths: ["Vendor/DesignTokens"]
          exemptPaletteFiles: ["Sources/WinePalette.swift"]
          exemptTestPaths: ["**/Tests/**"]
        """)
        let forms = ConfigurationExclusions.active(in: configuration).map(\.form)
        #expect(forms == [
            "designTokens.exemptPackagePaths", "designTokens.exemptPaletteFiles", "designTokens.exemptTestPaths",
        ])
    }

    @Test("A misspelt key is refused, not silently dropped")
    func unknownKeyRefused() {
        #expect(throws: (any Error).self) {
            _ = try Configuration.from(yaml: "designTokens:\n  enabled: true\n  paletteFiles: [\"A.swift\"]\n")
        }
    }
}
