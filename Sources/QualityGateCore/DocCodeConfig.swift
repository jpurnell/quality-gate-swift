import Foundation

/// Configuration for the `doc-code` checker.
///
/// The checker compiles the fenced Swift in DocC articles against the built module.
/// Everything here narrows *what* it compiles or *how* it reaches the module; nothing
/// here weakens the verdict, because a knob that turns a red gate green is a suppression
/// by another name.
public struct DocCodeConfig: Sendable, Codable, Equatable {

    /// Also audit the repository's top-level `README.md`.
    ///
    /// Off by default. A README's fences are frequently written against a *consumer* of
    /// the package (a fresh executable, an app target) rather than against the module
    /// itself, so compiling it as an extension of the library's namespace produces
    /// findings about the harness rather than the documentation.
    public var includeReadme: Bool

    /// Extra markdown files to audit, as paths relative to the project root.
    ///
    /// Additive to the discovered `.docc` catalogues — never a replacement, so a
    /// configured path cannot narrow coverage by accident.
    public var additionalArticles: [String]

    /// Imports prepended to every assembled article, beyond `Foundation` and the module
    /// the catalogue documents.
    ///
    /// For a package whose articles legitimately span two products (`BusinessMath` and
    /// `BusinessMathDSL`, say) without saying so in every block.
    public var extraImports: [String]

    /// Directory holding the built `.swiftmodule` to compile against.
    ///
    /// `nil` (the default) means `.build/debug` under the project root, which is where
    /// SwiftPM leaves a debug build. Set it when the gate runs against an alternate
    /// build path.
    public var moduleSearchPath: String?

    /// Extra header search paths, offered to Clang as `-Xcc -I<path>`.
    ///
    /// Additive to the C-target `include` directories discovered under `.build/checkouts`,
    /// never a replacement — a knob that could *narrow* the search would be a suppression by
    /// another name, and the failure it would hide is the expensive one: an article that
    /// cannot resolve its imports does not fail loudly, it stops being compiled at all.
    ///
    /// For a package whose C dependencies are vendored somewhere SwiftPM's checkout layout
    /// does not describe.
    public var headerSearchPaths: [String]

    /// Maximum number of `<!-- docs:illustrative -->` blocks tolerated across the
    /// catalogue before the checker warns.
    ///
    /// `nil` (the default) disables the ceiling. The exemption count is *always*
    /// reported; this only decides whether growth in it is worth a warning. Exemptions
    /// are the one place a documentation gate silently erodes, and a cluster of them
    /// sharing one construct is usually a tooling bug rather than a documentation
    /// pattern.
    public var exemptionCeiling: Int?

    /// Creates a configuration; every knob defaults to the documented value.
    public init(
        includeReadme: Bool = false,
        additionalArticles: [String] = [],
        extraImports: [String] = [],
        moduleSearchPath: String? = nil,
        headerSearchPaths: [String] = [],
        exemptionCeiling: Int? = nil
    ) {
        self.includeReadme = includeReadme
        self.additionalArticles = additionalArticles
        self.extraImports = extraImports
        self.moduleSearchPath = moduleSearchPath
        self.headerSearchPaths = headerSearchPaths
        self.exemptionCeiling = exemptionCeiling
    }

    private enum CodingKeys: String, CodingKey {
        case includeReadme, additionalArticles, extraImports, moduleSearchPath
        case headerSearchPaths, exemptionCeiling
    }

    /// Decodes with defaults for absent keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includeReadme = try container.decodeIfPresent(Bool.self, forKey: .includeReadme) ?? false
        additionalArticles = try container.decodeIfPresent([String].self, forKey: .additionalArticles) ?? []
        extraImports = try container.decodeIfPresent([String].self, forKey: .extraImports) ?? []
        moduleSearchPath = try container.decodeIfPresent(String.self, forKey: .moduleSearchPath)
        headerSearchPaths = try container.decodeIfPresent([String].self, forKey: .headerSearchPaths) ?? []
        exemptionCeiling = try container.decodeIfPresent(Int.self, forKey: .exemptionCeiling)
    }
}
