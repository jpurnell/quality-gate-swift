import IndexStoreDB

/// Finds the other modules' copies of a declaration.
///
/// A source file compiled into several modules — an Xcode project with a target per platform
/// sharing its sources — defines each of its declarations once per module, each under its own
/// USR (`s:7TargetA6SharedV…`, `s:7TargetB6SharedV…`). IndexStoreDB's file queries answer from
/// one compilation of a file, so a pass that starts from them sees one copy and the references
/// its module makes, and nothing of the others. Which copy is seen follows build order.
///
/// A copy is found by name, then confirmed by place: the same kind of symbol, defined at the
/// same line and column of the same file. A symbol of the same name declared anywhere else is
/// a different declaration and is not returned.
struct DeclarationCopies {
    private let db: IndexStoreDB
    private let canonicalize: (String) -> String
    /// Canonical occurrences by name. A name is looked up once, however many files mention it.
    private var byName: [String: [SymbolOccurrence]] = [:]

    /// Creates a finder over `db`.
    ///
    /// - Parameters:
    ///   - db: The index.
    ///   - canonicalize: Resolves a path the index records to the form the pass compares.
    init(db: IndexStoreDB, canonicalize: @escaping (String) -> String) {
        self.db = db
        self.canonicalize = canonicalize
    }

    /// The other modules' copies of `symbol`'s declaration.
    ///
    /// - Parameter symbol: A symbol the index returned for some file.
    /// - Returns: Every other symbol declared at the same place, or an empty array when the
    ///   declaration was compiled into one module or the index records no definition of it.
    mutating func of(_ symbol: Symbol) -> [Symbol] {
        guard !symbol.name.isEmpty else { return [] }
        let candidates = occurrences(named: symbol.name)
        guard let own = candidates.first(where: { $0.symbol.usr == symbol.usr }) else { return [] }
        let file = canonicalize(own.location.path)
        var seen: Set<String> = [symbol.usr]
        var result: [Symbol] = []
        for candidate in candidates
        where candidate.symbol.kind == symbol.kind
            && candidate.location.line == own.location.line
            && candidate.location.utf8Column == own.location.utf8Column
            && canonicalize(candidate.location.path) == file
            && seen.insert(candidate.symbol.usr).inserted {
            result.append(candidate.symbol)
        }
        return result
    }

    private mutating func occurrences(named name: String) -> [SymbolOccurrence] {
        if let cached = byName[name] { return cached }
        let found = db.canonicalOccurrences(ofName: name)
        byName[name] = found
        return found
    }
}
