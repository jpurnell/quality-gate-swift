import Foundation

/// A single resolved reference: an occurrence, in `refModule`, of a symbol whose
/// definition (`defUSR`) lives in `defModule`.
///
/// These are produced by the IndexStore IO layer and consumed by the pure
/// ``SemanticGraphBuilder``. Keeping them abstract lets the graph/over-public
/// logic be unit-tested without a live index store — the same split the
/// complexity pass uses (a pure `run(inputs:)` fed pre-resolved edges).
public struct ReferenceFact: Sendable, Equatable, Hashable {
    /// USR of the referenced symbol's definition.
    public let defUSR: String
    /// Module that defines the symbol.
    public let defModule: String
    /// Module from which this particular reference is made.
    public let refModule: String

    /// Creates a reference fact.
    public init(defUSR: String, defModule: String, refModule: String) {
        self.defUSR = defUSR
        self.defModule = defModule
        self.refModule = refModule
    }
}

/// The semantic facts derived from resolved references.
public struct SemanticFacts: Sendable, Equatable {
    /// The module usage graph: an edge `A → B` means a file in `A` references a
    /// symbol defined in `B`, weighted by reference count.
    public let graph: ModuleGraph

    /// USRs of `public`/`open` symbols that are *alive but over-exposed*: they
    /// have at least one in-module reference and zero cross-module references.
    /// A symbol with no references at all is **not** here — that is dead code,
    /// owned by `UnreachableCodeAuditor`, not a legibility concern.
    public let overPublicUSRs: Set<String>

    /// USRs referenced at least once from anywhere (used to dedup against dead
    /// symbols: anything not in this set is unreferenced).
    public let referencedUSRs: Set<String>

    /// Creates semantic facts.
    public init(graph: ModuleGraph, overPublicUSRs: Set<String>, referencedUSRs: Set<String>) {
        self.graph = graph
        self.overPublicUSRs = overPublicUSRs
        self.referencedUSRs = referencedUSRs
    }
}

/// Builds the semantic module graph and over-public set from resolved references.
///
/// Pure and deterministic: given the same references and public-USR set it always
/// produces the same facts, independent of any index store.
public enum SemanticGraphBuilder {

    /// Derives ``SemanticFacts`` from resolved references.
    ///
    /// - Parameters:
    ///   - references: Every resolved reference, including in-module ones (needed
    ///     to distinguish over-public from dead).
    ///   - publicUSRs: USRs known (from the SwiftSyntax surface pass) to be
    ///     `public`/`open`. Only these are eligible to be over-public.
    public static func build(references: [ReferenceFact], publicUSRs: Set<String>) -> SemanticFacts {
        var edges: [String: Set<String>] = [:]
        var weights: [String: [String: Int]] = [:]
        var inModuleRefCount: [String: Int] = [:]
        var crossModuleRefCount: [String: Int] = [:]
        var referenced: Set<String> = []

        for fact in references {
            referenced.insert(fact.defUSR)
            if fact.refModule == fact.defModule {
                inModuleRefCount[fact.defUSR, default: 0] += 1
            } else {
                crossModuleRefCount[fact.defUSR, default: 0] += 1
                edges[fact.refModule, default: []].insert(fact.defModule)
                weights[fact.refModule, default: [:]][fact.defModule, default: 0] += 1
            }
        }

        var overPublic: Set<String> = []
        for usr in publicUSRs {
            let cross = crossModuleRefCount[usr] ?? 0
            let inModule = inModuleRefCount[usr] ?? 0
            if cross == 0 && inModule > 0 {
                overPublic.insert(usr)
            }
        }

        return SemanticFacts(
            graph: ModuleGraph(edges: edges, weights: weights),
            overPublicUSRs: overPublic,
            referencedUSRs: referenced
        )
    }
}
