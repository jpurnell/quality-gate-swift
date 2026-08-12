import Foundation
import QualityGateCore

/// Produces the body of one `<!-- generated:<id> -->` region.
///
/// ## The hermeticity obligation
///
/// A conformance may read **only files under `projectRoot`**. No clock, no network, no `git`
/// refs, no environment. This is a constraint on the protocol rather than a value the
/// protocol reports, and it has to be: `QualityChecker.hermeticity` is a `var` with no
/// parameters, answered before any file is read, so it cannot depend on which generators
/// happen to match regions in this tree. The tempting design — "report the weakest
/// hermeticity among the matched generators" — is not expressible, and the honest one is
/// that the set of admissible conformances is narrowed instead.
///
/// This is why the changelog generator derives its version list from the file's own headings
/// rather than from `git tag`: refs are not the working tree, and a shallow clone would move
/// the verdict without moving a byte of source.
///
/// ## Why there is no configured command
///
/// Two reasons, and the second survives even if the first does not move you. `GatePlugins`
/// does execute configured executables, and its trust rules make every plugin finding
/// advisory unless the entry declares `gates: true` — the safety of running a declared
/// command is bought by making its verdict non-binding, and this rule gates. Independently:
/// whoever can write a stale region can also write the command beside it that reproduces the
/// stale region, so a reference nominated by the document under test verifies nothing.
public protocol RegionGenerator: Sendable {

    /// The id that appears in `<!-- generated:<id> -->`.
    var id: String { get }

    /// One line naming what the content is derived from, printed with every finding.
    ///
    /// A reader has to be able to tell whether the document or the generator is the thing
    /// that is wrong. Sometimes it is the generator.
    var derivedFrom: String { get }

    /// The region body, computed from files under `projectRoot` only.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root. The only directory a conformance may read.
    ///   - currentBody: The bytes currently between the delimiters.
    ///
    ///     Roster generators need this and cannot be written without it: they are required to
    ///     preserve an existing tick-box and description *byte-for-byte* and to only add and
    ///     remove lines, which is a function of what is already there. A generator that
    ///     computes its output from the tree alone ignores this argument, and the one-character
    ///     comparison then behaves exactly as it would have without it.
    ///   - configuration: Supplies the checker's own knobs and the shared exclusions.
    /// - Returns: The body the region should contain, with no trailing newline.
    /// - Throws: ``RegionGeneratorError/ungeneratable(reason:)`` when a fact the generator
    ///   needs is absent. A throw is reported as a finding, never as a pass: a regeneration
    ///   that never happened is not a match.
    func generate(projectRoot: URL, currentBody: String, configuration: Configuration) throws -> String
}

/// Why a generator could not produce a region.
public enum RegionGeneratorError: Error, Sendable, Equatable {

    /// A fact the generator needs is not present in the tree or the configuration.
    ///
    /// Reported as an error rather than a skip. A region nothing regenerated is a region
    /// nothing checked, and silence there is indistinguishable from a pass.
    case ungeneratable(reason: String)
}

/// The generators compiled into this binary.
///
/// The set is a fact about the tool, enumerable from it and testable without a filesystem —
/// the same shape as the checker registry, for the same reason. A third-party generator
/// arrives as a new conformance in a new target, compiled in, where changing it is a code
/// review.
public enum RegionGeneratorRegistry {

    /// Every registered generator, in a stable order.
    public static var all: [any RegionGenerator] {
        [
            ChangelogLinksGenerator(),
            ErrorRegistryGenerator(),
            ModuleStructureGenerator(),
            StatusRosterGenerator(),
        ]
    }

    /// The registered ids.
    public static var ids: [String] { all.map(\.id) }

    /// The generator for an id, or `nil` when none is registered.
    ///
    /// - Parameter id: The id named by a region's delimiters.
    /// - Returns: The generator, or `nil`.
    public static func generator(for id: String) -> (any RegionGenerator)? {
        all.first { $0.id == id }
    }
}
