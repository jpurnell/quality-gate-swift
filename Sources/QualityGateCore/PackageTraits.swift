import Foundation

/// The SwiftPM package traits a run builds with, as the arguments SwiftPM takes.
///
/// One spelling for every invocation that builds the package — `build`, `test`, the index
/// build, the DocC build, the tools-version verification build. They must agree: SwiftPM
/// keeps one build directory per configuration, not per trait set, so two checkers asking
/// for different traits rebuild each other's products, and the index would describe code
/// that `build` did not compile.
///
/// SwiftKeychain is why this exists. Its adapters sit behind traits that are off by default,
/// and a trait-gated dependency is not even resolved while its trait is off — so before
/// `traits:`, every checker compiled, tested and indexed the package with those adapters
/// missing, and reported on what was left.
///
/// ## No "all traits"
///
/// SwiftPM also offers `--enable-all-traits`, and the configuration deliberately does not.
/// SE-0450 asks that traits be additive but SwiftPM does not enforce it, so a package can
/// define alternatives — and the union of alternatives is a build no consumer can ask for,
/// which the gate would then verify instead of the ones they can. It would also make what
/// the gate builds a property of `Package.swift` rather than of `.quality-gate.yml`: a trait
/// added to the manifest would change every checker's build with no line in the gate's
/// configuration saying so. An explicit list is the configuration a reviewer can read.
///
/// ## Usage
///
/// ```swift
/// import QualityGateCore
///
/// let arguments = ["build"] + PackageTraits.arguments(enabling: ["OAuth", "CLIAuth"])
/// // ["build", "--traits", "OAuth,CLIAuth"]
/// ```
public enum PackageTraits {

    /// The arguments that enable `traits`, or none when there are none.
    ///
    /// An empty list yields no arguments rather than an empty `--traits`, because the two
    /// are different requests: no flag is "the package's default traits", which is what a
    /// project without `traits:` has always been built with, while `--traits` with any value
    /// replaces the defaults. SwiftPM's own word `defaults` re-enables them alongside others,
    /// and is passed through like any other name.
    ///
    /// - Parameter traits: Trait names, in the order the configuration lists them.
    /// - Returns: `["--traits", "A,B"]`, or `[]`.
    public static func arguments(enabling traits: [String]) -> [String] {
        guard !traits.isEmpty else { return [] }
        return ["--traits", traits.joined(separator: ",")]
    }

    /// The first name SwiftPM would not read back as the trait it was written as.
    ///
    /// SwiftPM takes the list as one comma-separated value, so a name containing a comma
    /// becomes two traits, an empty one becomes a stray separator, and a name with
    /// whitespace is not a trait any manifest can declare. Each is refused at decoding rather
    /// than passed on: a build that silently enabled something other than what the file says
    /// is exactly the gap this key exists to close.
    ///
    /// - Parameter traits: Trait names as decoded.
    /// - Returns: The first unusable name, or `nil` when every name is usable.
    public static func unusableName(in traits: [String]) -> String? {
        traits.first { name in
            name.isEmpty || name.contains(",") || name.contains { $0.isWhitespace }
        }
    }
}
