import Foundation

/// Configuration for the `design-token-drift` checker.
///
/// The checker is opt-in: it reads nothing and reports `skipped` until ``enabled`` is `true`.
/// Once on, it flags colours, fonts, corner radii and grid widths written outside the design
/// tokens (`DesignTokenDriftIsAFinding.md`). Three kinds of file may write such a value, and each
/// is declared here as a path list rather than marked in the source:
///
/// - the tokens package itself (``exemptPackagePaths``),
/// - an app's own palette (``exemptPaletteFiles``), which the checker **validates** on every run
///   instead of skipping, and
/// - test files (``exemptTestPaths``), when the project chooses to exempt them.
///
/// Every list holds globs relative to the project root: `**` crosses directories, `*` and `?`
/// stay inside one path segment, and a pattern naming a directory covers everything beneath it.
///
/// ```yaml
/// designTokens:
///   enabled: true
///   exemptPaletteFiles: ["Sources/App/WinePalette.swift"]
///   exemptTestPaths: ["**/Tests/**"]
///   cssPaths: ["Assets/css/**"]
///   tokenFiles: ["Assets/css/tokens.css"]
/// ```
public struct DesignTokensConfig: Sendable, Codable, Equatable {

    /// Whether the checker runs. Default `false`: a project opts in.
    public var enabled: Bool

    /// Paths of the tokens package, exempt from the rules because it is where the values are defined.
    public var exemptPackagePaths: [String]

    /// Declared app-palette files. Exempt from the rules, and checked: a listed file that does not
    /// exist, or that defines no colour, is itself a finding.
    public var exemptPaletteFiles: [String]

    /// Test files, exempt when listed. Empty by default, which holds tests to the rule.
    public var exemptTestPaths: [String]

    /// Where CSS and HTML are checked. Empty means Swift only.
    public var cssPaths: [String]

    /// The generated token set: `tokens.css`, or the CSS files in DesignTokens' `Generated/`.
    /// They define the values, so they are read, not scanned.
    public var tokenFiles: [String]

    /// Creates a configuration; every knob defaults to the documented value.
    public init(
        enabled: Bool = false,
        exemptPackagePaths: [String] = [],
        exemptPaletteFiles: [String] = [],
        exemptTestPaths: [String] = [],
        cssPaths: [String] = [],
        tokenFiles: [String] = []
    ) {
        self.enabled = enabled
        self.exemptPackagePaths = exemptPackagePaths
        self.exemptPaletteFiles = exemptPaletteFiles
        self.exemptTestPaths = exemptTestPaths
        self.cssPaths = cssPaths
        self.tokenFiles = tokenFiles
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, exemptPackagePaths, exemptPaletteFiles, exemptTestPaths, cssPaths, tokenFiles
    }

    /// Decodes with defaults for absent keys, and refuses a key it does not define.
    ///
    /// The refusal is deliberate and local to this section. A misspelt `enabled` would opt the
    /// project out without a word, and a misspelt `exemptPaletteFiles` would leave a declaration
    /// that never applied; both read as a clean file. The error names the key.
    public init(from decoder: Decoder) throws {
        let written = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let known = Set([CodingKeys.enabled, .exemptPackagePaths, .exemptPaletteFiles, .exemptTestPaths, .cssPaths, .tokenFiles].map(\.stringValue))
        let unknown = written.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "designTokens has no key named \(unknown.map { "'\($0)'" }.joined(separator: ", ")); "
                    + "the keys are \(known.sorted().joined(separator: ", "))."))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        exemptPackagePaths = try container.decodeIfPresent([String].self, forKey: .exemptPackagePaths) ?? []
        exemptPaletteFiles = try container.decodeIfPresent([String].self, forKey: .exemptPaletteFiles) ?? []
        exemptTestPaths = try container.decodeIfPresent([String].self, forKey: .exemptTestPaths) ?? []
        cssPaths = try container.decodeIfPresent([String].self, forKey: .cssPaths) ?? []
        tokenFiles = try container.decodeIfPresent([String].self, forKey: .tokenFiles) ?? []
    }
}

/// A coding key that accepts any name, to list what was written.
private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
