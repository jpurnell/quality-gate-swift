import Foundation
import IndexStoreDB
import IndexStoreInfra

/// The semantic resolution produced from the IndexStore: the real module usage
/// graph (test-origin edges excluded, for a clean reading order) and the
/// over-public occurrences (public symbols referenced only within their module).
struct SemanticResolution: Sendable {
    /// The semantic module graph (source-to-source edges only).
    let graph: ModuleGraph
    /// Over-public occurrences, ready for the over-public rule.
    let overPublic: [OverPublicOccurrence]

    /// Creates a semantic resolution.
    init(graph: ModuleGraph, overPublic: [OverPublicOccurrence]) {
        self.graph = graph
        self.overPublic = overPublic
    }
}

/// Resolves the semantic module graph and over-public set from an IndexStore.
///
/// Only `public`/`open` symbols are queried for references — cross-module use is
/// only ever of the public surface, so this captures every inter-module edge
/// while avoiding a reference query for every internal symbol.
enum LegibilityIndexPass {

    /// The module that owns a file, from its `Sources/<Module>/` or
    /// `Tests/<Module>/` path segment. `nil` when neither segment is present.
    static func moduleName(fromFilePath path: String) -> String? {
        for marker in ["/Sources/", "/Tests/"] {
            guard let range = path.range(of: marker) else { continue }
            let after = path[range.upperBound...]
            if let first = after.split(separator: "/").first {
                return String(first)
            }
        }
        return nil
    }

    /// Whether a module is a test target (excluded from source-to-source edges).
    static func isTestModule(_ module: String) -> Bool {
        module.hasSuffix("Tests")
    }

    /// A public definition located in the index.
    private struct PublicDef {
        let usr: String
        let name: String
        let module: String
        let filePath: String
        let hasReservedMarker: Bool
    }

    /// Resolves the semantic graph and over-public occurrences.
    ///
    /// - Parameters:
    ///   - session: An open IndexStore session.
    ///   - sourceFiles: Absolute paths of `Sources/` Swift files (where public
    ///     definitions live).
    ///   - publicByFile: The SwiftSyntax public surface, keyed by file path.
    ///   - exemptSymbols: Fully-qualified (`Module.name`) or bare names that
    ///     acknowledge an intentional over-public symbol.
    static func resolve(
        session: IndexStoreSession,
        sourceFiles: [String],
        publicByFile: [String: [PublicSymbol]],
        exemptSymbols: Set<String>
    ) -> SemanticResolution {
        let publicDefs = collectPublicDefs(session: session, sourceFiles: sourceFiles, publicByFile: publicByFile)
        let publicUSRs = Set(publicDefs.map(\.usr))

        // Query references only for public symbols; split into all vs. non-test-origin.
        var allRefs: [ReferenceFact] = []
        var sourceRefs: [ReferenceFact] = []
        for def in publicDefs {
            let refs = ConformanceQuery.findReferences(
                toUSR: def.usr,
                in: session,
                roles: [.reference, .call, .read, .write]
            )
            for ref in refs {
                guard let refModule = moduleName(fromFilePath: ref.filePath) else { continue }
                let fact = ReferenceFact(defUSR: def.usr, defModule: def.module, refModule: refModule)
                allRefs.append(fact)
                if !isTestModule(refModule) && !isTestModule(def.module) {
                    sourceRefs.append(fact)
                }
            }
        }

        // Graph from source-to-source edges; over-public from all references
        // (a test-only reference counts as cross-module, so test-only-public is
        // not flagged — matching the proposal).
        let graphFacts = SemanticGraphBuilder.build(references: sourceRefs, publicUSRs: [])
        let overFacts = SemanticGraphBuilder.build(references: allRefs, publicUSRs: publicUSRs)

        let occurrences = buildOccurrences(
            overPublicUSRs: overFacts.overPublicUSRs,
            defsByUSR: Dictionary(publicDefs.map { ($0.usr, $0) }, uniquingKeysWith: { first, _ in first }),
            session: session,
            exemptSymbols: exemptSymbols
        )

        return SemanticResolution(graph: graphFacts.graph, overPublic: occurrences)
    }

    // MARK: - Helpers

    private static func collectPublicDefs(
        session: IndexStoreSession,
        sourceFiles: [String],
        publicByFile: [String: [PublicSymbol]]
    ) -> [PublicDef] {
        // Only public *types* are eligible for the over-public rule — a public
        // member of a public type is part of that type's contract, not an
        // independent over-exposure. Build eligible (and reserved) names per file.
        var publicNames: [String: Set<String>] = [:]
        var reservedNames: [String: Set<String>] = [:]
        for (file, symbols) in publicByFile {
            let types = symbols.filter { $0.kind.isType }
            publicNames[file] = Set(types.map(\.name))
            reservedNames[file] = Set(types.filter(\.hasReservedMarker).map(\.name))
        }

        var defs: [PublicDef] = []
        var seenUSRs: Set<String> = []
        for (symbol, filePath) in ConformanceQuery.symbolsInFiles(sourceFiles, in: session) {
            guard let module = moduleName(fromFilePath: filePath) else { continue }
            guard publicNames[filePath]?.contains(symbol.name) == true else { continue }
            guard !seenUSRs.contains(symbol.usr) else { continue }
            seenUSRs.insert(symbol.usr)
            defs.append(PublicDef(
                usr: symbol.usr,
                name: symbol.name,
                module: module,
                filePath: filePath,
                hasReservedMarker: reservedNames[filePath]?.contains(symbol.name) == true
            ))
        }
        return defs
    }

    private static func buildOccurrences(
        overPublicUSRs: Set<String>,
        defsByUSR: [String: PublicDef],
        session: IndexStoreSession,
        exemptSymbols: Set<String>
    ) -> [OverPublicOccurrence] {
        var occurrences: [OverPublicOccurrence] = []
        for usr in overPublicUSRs {
            guard let def = defsByUSR[usr] else { continue }
            let exemptByConfig = exemptSymbols.contains("\(def.module).\(def.name)") || exemptSymbols.contains(def.name)
            let acknowledged = def.hasReservedMarker || exemptByConfig
            let annotation = def.hasReservedMarker ? "legibility:reserved" : (exemptByConfig ? "exemptSymbols" : nil)
            let line = session.db.occurrences(ofUSR: usr, roles: [.definition]).first?.location.line ?? 0
            occurrences.append(OverPublicOccurrence(
                symbolName: def.name,
                moduleName: def.module,
                filePath: def.filePath,
                line: line,
                acknowledged: acknowledged,
                acknowledgment: annotation
            ))
        }
        return occurrences
    }
}
