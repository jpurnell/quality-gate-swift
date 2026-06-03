import Foundation
import IndexStoreDB

/// High-level query helpers for protocol conformance and symbol relationships.
///
/// Wraps IndexStoreDB's raw symbol/occurrence API into checker-friendly
/// operations like "find all types conforming to protocol X" or "find
/// all references to symbol Z".
public enum ConformanceQuery {

    /// A type that conforms to a protocol, with file location.
    public struct Conformer: Sendable {
        /// The name of the conforming type.
        public let typeName: String
        /// The Unified Symbol Resolution identifier for the conforming type.
        public let usr: String
        /// The absolute path to the file where the conformance is declared.
        public let filePath: String
        /// The source line number of the conformance declaration.
        public let line: Int

        /// Creates a new conformer with the given type name, USR, file path, and line.
        public init(typeName: String, usr: String, filePath: String, line: Int) {
            self.typeName = typeName
            self.usr = usr
            self.filePath = filePath
            self.line = line
        }
    }

    /// A reference to a symbol, with file location.
    public struct SymbolReference: Sendable {
        /// The name of the referenced symbol.
        public let symbolName: String
        /// The Unified Symbol Resolution identifier for the symbol.
        public let usr: String
        /// The absolute path to the file containing this reference.
        public let filePath: String
        /// The source line number of this reference.
        public let line: Int
        /// The symbol roles associated with this reference (e.g. call, read, write).
        public let roles: SymbolRole

        /// Creates a new symbol reference with the given name, USR, location, and roles.
        public init(symbolName: String, usr: String, filePath: String, line: Int, roles: SymbolRole) {
            self.symbolName = symbolName
            self.usr = usr
            self.filePath = filePath
            self.line = line
            self.roles = roles
        }
    }

    /// Find all types conforming to a protocol by name.
    ///
    /// Searches for symbols named `protocolName` that are protocols,
    /// then finds all types with a `.baseOf` or `.overrideOf` relation
    /// to that protocol's USR.
    public static func findConformers(
        ofProtocol protocolName: String,
        in session: IndexStoreSession,
        limitToFiles files: Set<String>? = nil
    ) -> [Conformer] {
        let candidates = session.db.canonicalOccurrences(
            containing: protocolName,
            anchorStart: false,
            anchorEnd: false,
            subsequence: false,
            ignoreCase: false
        )

        var protocolUSRs: [String] = []
        for occ in candidates {
            if occ.symbol.kind == .protocol, occ.symbol.name == protocolName {
                protocolUSRs.append(occ.symbol.usr)
            }
        }

        var conformers: [Conformer] = []
        for protocolUSR in protocolUSRs {
            let occs = session.db.occurrences(
                ofUSR: protocolUSR,
                roles: [.reference, .baseOf]
            )
            for occ in occs {
                for rel in occ.relations {
                    if rel.roles.contains(.baseOf) {
                        if let files, !files.contains(occ.location.path) { continue }
                        conformers.append(Conformer(
                            typeName: rel.symbol.name,
                            usr: rel.symbol.usr,
                            filePath: occ.location.path,
                            line: occ.location.line
                        ))
                    }
                }
            }
        }
        return conformers
    }

    /// Find all occurrences of a symbol by USR.
    public static func findReferences(
        toUSR usr: String,
        in session: IndexStoreSession,
        roles: SymbolRole = [.reference, .call, .read, .write]
    ) -> [SymbolReference] {
        let occs = session.db.occurrences(ofUSR: usr, roles: roles)
        return occs.map { occ in
            SymbolReference(
                symbolName: occ.symbol.name,
                usr: occ.symbol.usr,
                filePath: occ.location.path,
                line: occ.location.line,
                roles: occ.roles
            )
        }
    }

    /// Find all symbols defined in a set of files.
    public static func symbolsInFiles(
        _ files: [String],
        in session: IndexStoreSession
    ) -> [(symbol: Symbol, filePath: String)] {
        var results: [(Symbol, String)] = []
        for file in files {
            let symbols = session.db.symbols(inFilePath: file)
            for symbol in symbols {
                results.append((symbol, file))
            }
        }
        return results
    }
}
