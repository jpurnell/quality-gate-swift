import Foundation

/// Hand-curated portion of the well-known protocol-witness allow-list.
///
/// `WellKnownWitnesses.all` is the union of this set and the
/// auto-generated `WellKnownWitnesses+Generated.swift` set, which is
/// produced by `scripts/regenerate-witnesses.sh` from the current Swift
/// toolchain's symbol graph.
///
/// Put names here that the symbol-graph extractor *can't* know about:
/// - operator implementations (`==`, `<`, …)
/// - conventional names that may or may not be protocol requirements
///   depending on the type (e.g. `body` in a SwiftUI `View` vs. some
///   unrelated type)
/// - names that vanish through macro expansion before reaching the
///   symbol graph (the `@Observable` accessor pattern)
///
/// Anything that *is* a protocol requirement in a stdlib / SwiftUI /
/// Foundation module belongs in the generated file, not here — that way
/// it stays in sync with new SDKs automatically.
enum WellKnownWitnesses {

    /// Hand-curated names. Edit by hand; small and stable.
    static let curated: Set<String> = [
        // Equatable / Comparable operator implementations. Operators are
        // recorded as standalone functions in the symbol graph, not as
        // requirements of `Equatable.==` etc., so we keep them here.
        "==", "!=", "<", "<=", ">", ">=",
        // Convention: SwiftUI `View.body`, `Scene.body`, `Widget.body`,
        // `Commands.body`, etc. all share the name `body`. The symbol
        // graph would catch each protocol's requirement, but a method
        // literally called `body` on any unrelated type is also commonly
        // a witness candidate.
        "body",
    ]

    /// Union of the curated set and the auto-generated set. This is what
    /// `IndexStorePass` consults.
    static let all: Set<String> = curated.union(generated)
}
