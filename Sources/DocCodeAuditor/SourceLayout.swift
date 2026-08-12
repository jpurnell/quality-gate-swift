import Foundation

/// The directory names SwiftPM permits for a package's sources.
///
/// `Sources` is the convention and very nearly universal, which is why hardcoding it looked like
/// naming a constant rather than making an assumption. It is not a rule: `mlx-swift` uses
/// `Source`, and C-heavy packages wrapped for SwiftPM sometimes use `src`.
///
/// The cost of getting this wrong is asymmetric, and that asymmetry is the reason this type
/// exists. For a *dependency*, missing the directory costs a barrier — loud, and the diagnostic
/// says the count means nothing. For the *project under test*, it costs zero discovered articles,
/// which is reported exactly as "nothing wrong" and passes. A checker that examined nothing and a
/// checker that found nothing must never print the same thing.
enum SourceLayout {

    /// Probed in order; a package normally has exactly one of them.
    static let spellings = ["Sources", "Source", "src"]

    /// Whether a path component names a source root.
    static func isSourceRoot(_ component: String) -> Bool {
        spellings.contains(component)
    }
}
