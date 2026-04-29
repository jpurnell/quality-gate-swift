import Foundation
import QualityGateCore
import IndexStoreDB

/// Cross-module dead-code analysis backed by IndexStoreDB (v3).
///
/// Builds a call graph from the index, BFS-walks it from a root set
/// derived from the v2 liveness allow-list (public library API,
/// `@main`, `@objc`, `unitTest`, witnesses, `// LIVE:` exemptions,
/// top-level statements in `main.swift`), and reports any checkable
/// symbol that the walk does not reach.
struct IndexStorePass {

    struct Inputs {
        /// Root of the project being audited (for source enumeration).
        var rootURL: URL
        /// Configuration excludes are honored when walking sources.
        var excludePatterns: [String]
        var indexStorePath: URL
        var libIndexStoreDylib: URL
        /// Module-name → target type ("library", "executable", "test", ...).
        /// Empty for Xcode/Plain modes; the heuristic in `targetType(forModule:)`
        /// fills in defaults.
        var targetTypeByModule: [String: String]

        /// Resolve the target type for a given module name. SwiftPM mode
        /// has authoritative entries; Xcode/Plain modes fall back to a
        /// `Tests`/`UITests` suffix heuristic and otherwise treat the
        /// module as a `library` (the safe non-flagging default — see the
        /// design proposal for v4 question 2).
        func targetType(forModule module: String) -> String {
            if let t = targetTypeByModule[module] { return t }
            if module.hasSuffix("Tests") || module.hasSuffix("UITests") { return "test" }
            return "library"
        }
    }

    static func run(inputs: Inputs) throws -> [Diagnostic] {
        let lib = try IndexStoreLibrary(dylibPath: inputs.libIndexStoreDylib.path)
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality-gate-indexdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbPath) }

        let db = try IndexStoreDB(
            storePath: inputs.indexStorePath.path,
            databasePath: dbPath.path,
            library: lib,
            waitUntilDoneInitializing: true,
            listenToUnitEvents: false
        )
        db.pollForUnitChangesAndWait()

        // -- Pre-pass: gather syntactic facts for every source file under
        // the project root (recursively, skipping build/dependency dirs).
        var liveness = LivenessIndex()
        let swiftFiles = SourceWalker.swiftFiles(
            under: inputs.rootURL,
            excludePatterns: inputs.excludePatterns)
        for file in swiftFiles {
            guard let src = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            liveness.ingest(file: file, source: src)
        }

        // -- Pass 1: collect every checkable definition keyed by USR.
        struct DefRecord {
            var symbol: Symbol
            var defFile: String
            var defLine: Int
            var defColumn: Int
            var fact: DeclFact?
            var moduleName: String
            var targetType: String
        }
        var defs: [String: DefRecord] = [:]

        for file in swiftFiles {
            let symbols = db.symbols(inFilePath: file)
            for symbol in symbols {
                guard Self.isCheckable(symbol) else { continue }
                if defs[symbol.usr] != nil { continue }
                let defOccs = db.occurrences(ofUSR: symbol.usr, roles: [.definition])
                guard let def = defOccs.first(where: { $0.location.path == file }) ?? defOccs.first else {
                    continue
                }
                let defFile = def.location.path
                let defLine = def.location.line
                let moduleName = def.location.moduleName
                defs[symbol.usr] = DefRecord(
                    symbol: symbol,
                    defFile: defFile,
                    defLine: defLine,
                    defColumn: def.location.utf8Column,
                    fact: liveness.fact(file: defFile, line: defLine),
                    moduleName: moduleName,
                    targetType: inputs.targetType(forModule: moduleName)
                )
            }
        }

        // -- Pass 2: identify root USRs (the live set's seed).
        var roots = Set<String>()
        let allRoles = SymbolRole(rawValue: ~0)

        for (usr, rec) in defs {
            // unitTest property → root.
            if rec.symbol.properties.contains(.unitTest) { roots.insert(usr); continue }
            // Test target symbols → roots (test runner is the entry point).
            if rec.targetType == "test" { roots.insert(usr); continue }
            // // LIVE: exemption → root.
            if liveness.hasLiveExemption(file: rec.defFile, line: rec.defLine) {
                roots.insert(usr); continue
            }
            // @objc / @IBAction / @_cdecl / @_silgen_name → root.
            if rec.fact?.isObjC == true { roots.insert(usr); continue }
            // @main type / member → root.
            if rec.fact?.isMainAttr == true { roots.insert(usr); continue }
            // Public/open in library product → API surface → root.
            if (rec.fact?.isPublic == true) && rec.targetType == "library" {
                roots.insert(usr); continue
            }
            // Initializers: kept alive whenever the type itself is reachable;
            // we cannot model that precisely yet, so treat as roots.
            if rec.fact?.isInit == true { roots.insert(usr); continue }
            // Cases of `enum X: CodingKey` (or named `CodingKeys`) are
            // referenced only by synthesized Codable machinery — root.
            if rec.fact?.isCodingKey == true { roots.insert(usr); continue }
            // v6: protocol-witness allow-list. Combines:
            //   1. The hand-curated set (operators, conventional names
            //      like `body` that aren't universally requirements).
            //   2. The auto-generated set extracted from the Swift
            //      toolchain's symbol graph (Foundation, SwiftUI, UIKit,
            //      AppKit, Combine, SwiftData, Observation, …).
            // The generated set is updated by `scripts/regenerate-witnesses.sh`
            // and refreshes automatically when Apple ships a new SDK.
            if WellKnownWitnesses.all.contains(rec.symbol.name) {
                roots.insert(usr); continue
            }
            // Witness fallback: any def whose own relations include
            // `.overrideOf` (protocol requirement) is treated as a root.
            // This handles the user-defined protocol case (where the
            // index *does* record the relation correctly); cross-module
            // stdlib/SwiftUI conformances need the allow-list above.
            let defOccs = db.occurrences(
                ofUSR: usr,
                roles: [.definition, .declaration]
            )
            let isWitness = defOccs.contains { occ in
                occ.relations.contains { rel in
                    rel.roles.contains(.overrideOf) || rel.roles.contains(.baseOf)
                }
            }
            if isWitness { roots.insert(usr); continue }
        }
        _ = allRoles  // (kept for potential future use)

        // -- Pass 3: build the call/reference graph.
        // Edge convention: caller-USR → callee-USR.
        //
        // We compute the enclosing decl of a reference *lexically* via
        // SwiftSyntax (Liveness.enclosingDeclNameLine) instead of relying
        // on IndexStoreDB's `.containedBy` / `.calledBy` relations, which
        // are unreliable for many Swift constructs (static method calls,
        // stored-property reads, generics, etc).
        //
        // Top-level references in main.swift have no enclosing decl; we
        // promote their callees to roots directly.
        var edges: [String: Set<String>] = [:]

        // (file, defLine) → USR — used to map an enclosing-decl name line
        // back to the USR for that declaration.
        var defByLocation: [String: [Int: String]] = [:]
        for (usr, rec) in defs {
            defByLocation[rec.defFile, default: [:]][rec.defLine] = usr
        }

        for file in swiftFiles {
            let symbols = db.symbols(inFilePath: file)
            for symbol in symbols {
                let occs = db.occurrences(
                    ofUSR: symbol.usr,
                    roles: [.reference, .call, .read, .write]
                )
                for occ in occs where occ.location.path == file {
                    let refLine = occ.location.line
                    if let enclosingLine = liveness.enclosingDeclNameLine(file: file, line: refLine),
                       let callerUSR = defByLocation[file]?[enclosingLine] {
                        edges[callerUSR, default: []].insert(symbol.usr)
                    } else {
                        // No enclosing decl — top-level statement. main.swift
                        // (or any other top-level script) seeds roots.
                        if (file as NSString).lastPathComponent == "main.swift" {
                            roots.insert(symbol.usr)
                        }
                    }
                }
            }
        }

        // -- Pass 4: BFS the live set from the roots.
        var live = Set<String>()
        var queue = Array(roots)
        while let cur = queue.popLast() {
            if !live.insert(cur).inserted { continue }
            if let outs = edges[cur] {
                for callee in outs where !live.contains(callee) {
                    queue.append(callee)
                }
            }
        }

        // -- Pass 5: emit diagnostics.
        //
        // Conservative final filter (v3.1): a symbol is flagged only when
        // BOTH the BFS reachability pass and the v2-style "incoming refs"
        // pass agree that it is dead. This eliminates false positives that
        // occur when our call graph misses an edge (path-canonicalization
        // mismatches between SwiftSyntax and IndexStoreDB, generic methods,
        // closures, computed-property accessors, etc.) at the cost of
        // losing dead-chain detection — every link of an `A→B→C` chain
        // would still have to have zero refs to be flagged.
        var diagnostics: [Diagnostic] = []
        for (usr, rec) in defs {
            if live.contains(usr) { continue }
            if rec.targetType == "test" { continue }
            // v5: skip names that match a macro-generated pattern (silent
            // — these can't be user-written and we have nothing to flag).
            if Self.looksMacroGenerated(rec.symbol.name) { continue }
            // Empty-name symbols come from anonymous things we can't act on.
            if rec.symbol.name.isEmpty { continue }
            // Fallback: if we still don't have a SwiftSyntax decl at the
            // reported line, the symbol is probably compiler-synthesized
            // by a path our visitor doesn't yet handle. Skip rather than
            // emit a false positive — but the looksMacroGenerated rule
            // above is the preferred filter.
            if rec.fact == nil { continue }
            let refs = db.occurrences(
                ofUSR: usr,
                roles: [.reference, .call, .read, .write]
            )
            let externalRefs = refs.filter { occ in
                !(occ.location.path == rec.defFile && occ.location.line == rec.defLine)
            }
            if !externalRefs.isEmpty { continue }
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Symbol '\(rec.symbol.name)' is unreachable from any entry point.",
                filePath: rec.defFile,
                lineNumber: rec.defLine,
                columnNumber: rec.defColumn,
                ruleId: "unreachable.cross_module.unreachable_from_entry",
                suggestedFix: "Remove '\(rec.symbol.name)', or mark its declaration with `// LIVE:` if it is invoked dynamically."
            ))
        }

        // Stable order — useful for golden output and human review.
        diagnostics.sort { lhs, rhs in
            if (lhs.filePath ?? "") != (rhs.filePath ?? "") { return (lhs.filePath ?? "") < (rhs.filePath ?? "") }
            return (lhs.lineNumber ?? 0) < (rhs.lineNumber ?? 0)
        }

        return diagnostics
    }

    // MARK: - Helpers

    /// v5 macro-pattern recogniser. Compiler-/macro-synthesized symbols
    /// (`@Observable`, member-wise inits, etc.) have characteristic name
    /// shapes that the user can't have written by hand. We skip them
    /// silently rather than emit a false positive.
    static func looksMacroGenerated(_ name: String) -> Bool {
        if name.hasPrefix("_$") { return true }                       // _$observationRegistrar
        if name.hasPrefix("_"),
           let second = name.dropFirst().first, second.isLetter {
            return true                                                // _id, _name, _correlationR
        }
        // Macro-generated memberwise inits look like `init:name` — colon
        // between bare identifiers, no parentheses. Real Swift function
        // names always include `(...)` (e.g. `doStuff(arg:)`).
        if name.contains(":") && !name.contains("(") { return true }
        switch name {
        case "withMutation(keyPath:_:)", "access(keyPath:)",
             "shouldNotifyObservers(_:_:)":
            return true
        default:
            return false
        }
    }

    private static func isCheckable(_ symbol: Symbol) -> Bool {
        // Skip compiler-synthesized accessors (top-level `let foo` produces
        // `setter:foo` / `getter:foo` symbols in the index).
        if symbol.name.hasPrefix("setter:") || symbol.name.hasPrefix("getter:") { return false }
        switch symbol.kind {
        case .function, .instanceMethod, .staticMethod, .classMethod,
             .variable, .instanceProperty, .staticProperty, .classProperty,
             .enumConstant:
            return true
        default:
            return false
        }
    }

}
