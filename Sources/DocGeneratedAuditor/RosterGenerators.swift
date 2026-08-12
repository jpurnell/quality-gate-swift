import Foundation
import QualityGateCore

/// Generates `master_plan.md`'s architecture list from the targets the package declares.
///
/// The single largest drift measured in this repository: 34 modules listed against 61 present,
/// **27 absent**, and no phantoms. Revision 1 of the design deferred this on the argument that
/// a table nobody has needed in two months has earned deletion rather than automation. It was
/// overruled, and the reason is what a 44%-wrong table is *for*: it is the first thing a new
/// contributor reads and the first thing an agent reads at session start. The memory index
/// carries `project_architecture.md`, generated from the tree, saying 116 targets, while the
/// plan it sits beside says 34. One of those is derived and one is remembered.
public struct ModuleStructureGenerator: RegionGenerator {

    /// The id that appears in the region's delimiters.
    public let id = "module-structure"

    /// What a reader should check when this region disagrees with the document.
    public let derivedFrom =
        "the non-test targets declared in Package.swift, with each module's DocC abstract"

    /// Creates the generator.
    public init() {}

    /// One line per non-test target, in declaration order.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root; `Package.swift` and the DocC catalogues are read.
    ///   - currentBody: Existing lines, whose descriptions are preserved byte-for-byte.
    ///   - configuration: Unused by this generator.
    /// - Returns: The lines, newline-separated, with no trailing newline.
    /// - Throws: ``RegionGeneratorError/ungeneratable(reason:)`` when the manifest cannot be read.
    public func generate(
        projectRoot: URL, currentBody: String, configuration: Configuration
    ) throws -> String {
        let targets = try RosterSupport.targets(projectRoot: projectRoot)
        return Roster.merge(body: currentBody, members: targets) { module in
            "- `\(module)` — \(RosterSupport.description(of: module, projectRoot: projectRoot))"
        }.joined(separator: "\n")
    }
}

/// Generates the membership of `master_plan.md`'s §Current Status checklist — and nothing else.
///
/// The tick-box is `StatusAuditor`'s and stays `StatusAuditor`'s. What had drifted here is the
/// set: 47 entries, **16 real modules with no line at all**, and — after §8.6 corrected the
/// measuring script that produced them — **zero** entries naming something that does not exist.
/// A checklist can be wrong by omission long before it is wrong by assertion, and only the
/// omissions are derivable.
public struct StatusRosterGenerator: RegionGenerator {

    /// The id that appears in the region's delimiters.
    public let id = "status-roster"

    /// What a reader should check when this region disagrees with the document.
    public let derivedFrom =
        "the non-test targets declared in Package.swift (membership only; the tick-box is `status`'s)"

    /// Creates the generator.
    public init() {}

    /// One line per non-test target, with every existing tick-box and description untouched.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root; `Package.swift` and the DocC catalogues are read.
    ///   - currentBody: Existing lines, preserved byte-for-byte where their subject survives.
    ///   - configuration: Unused by this generator.
    /// - Returns: The lines, newline-separated, with no trailing newline.
    /// - Throws: ``RegionGeneratorError/ungeneratable(reason:)`` when the manifest cannot be read.
    public func generate(
        projectRoot: URL, currentBody: String, configuration: Configuration
    ) throws -> String {
        let targets = try RosterSupport.targets(projectRoot: projectRoot)
        return Roster.merge(body: currentBody, members: targets) { module in
            "- [ ] \(module) — \(RosterSupport.description(of: module, projectRoot: projectRoot))"
        }.joined(separator: "\n")
    }
}

/// What the two package-derived rosters share.
enum RosterSupport {

    /// Shown where no abstract exists, so an unwritten description is visible rather than blank.
    static let placeholder = "<!-- needs a description -->"

    /// The declared non-test targets, or a throw a reader can act on.
    static func targets(projectRoot: URL) throws -> [String] {
        guard let targets = PackageTargets.load(projectRoot: projectRoot) else {
            throw RegionGeneratorError.ungeneratable(
                reason: "`Package.swift` is absent, unreadable, or declares no `targets:`. An "
                    + "empty roster would read as a package with no modules, which is a "
                    + "different claim from one whose manifest could not be parsed.")
        }
        return targets
    }

    /// A module's DocC abstract, or a visible placeholder.
    ///
    /// Used only for a module that has no line yet. A description someone has already written
    /// is preserved against it: the abstract supplies what nobody has written, and does not
    /// overrule what somebody has.
    static func description(of module: String, projectRoot: URL) -> String {
        PackageTargets.doccAbstract(of: module, projectRoot: projectRoot) ?? placeholder
    }
}
