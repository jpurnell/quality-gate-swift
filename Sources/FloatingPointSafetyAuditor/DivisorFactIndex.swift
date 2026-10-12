import Foundation
import SwiftSyntax

/// What one file says about the values its divisors are built from: which
/// names are constants, which comparisons hold where, and what changes a name.
///
/// ``FallbackGuardFacts`` answers "was the question asked before this use?" for
/// a divisor that is a plain reference. This answers a narrower question for a
/// divisor that is *not* one — `n - 1`, `6 * area`, a name bound to a literal —
/// and holds itself to a stricter bar, because arithmetic on a bound is only
/// worth anything if the bound is still true: a comparison counts only in the
/// region it dominates, and only while nothing has reassigned or redeclared
/// what it was about.
struct DivisorFactIndex {

    /// A span of the file, as UTF-8 offsets.
    struct Region {
        let start: Int
        let end: Int

        func contains(_ offset: Int) -> Bool {
            offset >= start && offset < end
        }
    }

    /// Where a name's value comes from.
    enum Source {
        /// `let name = initializer`, with the annotation where one was written.
        case constant(initializer: ExprSyntax, annotation: String?)
        /// The variable of `for name in lower..<upper`: never below `lower`.
        case rangeIndex(lower: [ExprSyntax])
        /// The index of `for (name, _) in xs.enumerated()`.
        case nonNegative
        /// Declared, and nothing is known about its value.
        case opaque
    }

    /// One declaration of one name.
    struct Binding {
        let name: String
        /// Where the name means this declaration.
        let region: Region
        /// Where the declaration is written.
        let offset: Int
        let source: Source
        /// The type as written, for a parameter or an annotated declaration.
        let typeText: String?
        /// `let`, a parameter that is not `inout`, a loop variable.
        let isImmutable: Bool
    }

    /// What a comparison says about its subject.
    enum Claim {
        /// The subject is above the threshold — or at least it, when not `strict`.
        case above(threshold: [ExprSyntax], strict: Bool)
        /// The subject's magnitude is above the threshold.
        case magnitudeAbove(threshold: [ExprSyntax], strict: Bool)
        /// The subject is not zero.
        case nonZero
        /// The subject is a count of something that is not empty.
        case atLeastOne
    }

    /// A claim about one value that holds throughout one region.
    struct Condition {
        /// The value, as ``FallbackSubjectKey`` names it.
        let key: String
        /// Every name the key mentions. A change to any of them ends the claim.
        let names: Set<String>
        let claim: Claim
        let region: Region
        /// Where the comparison is written.
        let offset: Int
    }

    /// A Bool member tested where a condition is expected: `guard bond.isSchedulable`.
    struct PredicateUse {
        /// The value it was asked of, or nil for a bare name.
        let base: String?
        let name: String
        let region: Region
        let offset: Int
    }

    /// A type or extension declared in this file.
    struct TypeRange {
        let name: String
        let region: Region
    }

    /// Something that may change a value: an assignment, an `inout` pass, a
    /// redeclaration of the name, or a method call.
    struct Change {
        let offset: Int
        /// What was changed, as a member path: `state.totalSteps` is
        /// `["state", "totalSteps"]`. It stops at a subscript, so `xs[i].a = 1`
        /// is a change to `xs`.
        let path: [String]
        /// The method called, or nil for an assignment.
        let method: String?
        /// The call is on an element — `xs[i].update()` — and so can change
        /// what `xs[i]` is, and cannot change how many of them there are.
        let isOnElement: Bool
        /// Set when the change is written in a closure or a local function,
        /// about a name declared outside it: the body that closure belongs to.
        ///
        /// When such code runs is not written down — `let reset = { n = 0 }` can
        /// sit above a guard on `n` and run below it — so within that body the
        /// change counts wherever it is written. Outside it the closure is
        /// other code, as a method of the same type is.
        let deferredWithin: Region?
    }

    /// Local declarations, by name.
    var bindings: [String: [Binding]] = [:]
    /// File-scope declarations, by name. A name declared twice is absent.
    var globals: [String: Binding] = [:]
    /// Names declared at file scope more than once.
    var ambiguousGlobals: Set<String> = []
    /// Stored properties, by type name and then by member name.
    var members: [String: [String: [Binding]]] = [:]
    var types: [TypeRange] = []
    /// Claims, by key.
    var conditions: [String: [Condition]] = [:]
    var predicateUses: [PredicateUse] = []
    /// What a Bool computed property guarantees when it returns true, by type
    /// name and then by property name. Keys are relative to `self`.
    var predicates: [String: [String: [Condition]]] = [:]
    /// Everything that may change a value, by the name its path starts from.
    var changes: [String: [Change]] = [:]
    var loops: [Region] = []

    // MARK: - Lookup

    /// The declaration `name` refers to at `offset`: the innermost one in reach.
    func binding(_ name: String, at offset: Int) -> Binding? {
        var innermost: Binding?
        for candidate in bindings[name] ?? [] where candidate.region.contains(offset) {
            guard let current = innermost, current.region.start >= candidate.region.start else {
                innermost = candidate
                continue
            }
        }
        return innermost
    }

    /// The types enclosing `offset`, innermost first.
    func enclosingTypes(at offset: Int) -> [TypeRange] {
        types.filter { $0.region.contains(offset) }.sorted { $0.region.start > $1.region.start }
    }

    /// The stored property a bare `name` refers to at `offset`, when no local
    /// declaration is in reach.
    ///
    /// A global is read only outside every type. Inside one, a bare name may
    /// be a member declared in another file, and a member is found first.
    func memberOrGlobal(_ name: String, at offset: Int) -> Binding? {
        let enclosing = enclosingTypes(at: offset)
        for type in enclosing {
            if let found = member(name, of: type.name) { return found }
            if members[type.name]?[name] != nil { return nil }
        }
        guard enclosing.isEmpty, !ambiguousGlobals.contains(name) else { return nil }
        return globals[name]
    }

    /// The one declaration of `name` in the type called `typeName`, or nil when
    /// there is none or more than one.
    func member(_ name: String, of typeName: String) -> Binding? {
        guard let declared = members[typeName]?[name], declared.count == 1 else { return nil }
        return declared.first
    }

    /// What `predicate` guarantees of `base` at a use of it.
    ///
    /// The type is taken from what is written: the annotation of the parameter
    /// or local the predicate was asked of, or the enclosing type for a bare
    /// name. A value whose type is not written here has no predicate.
    func guarantees(of use: PredicateUse) -> [Condition] {
        guard let typeName = typeName(of: use) else { return [] }
        return predicates[typeName]?[use.name] ?? []
    }

    private func typeName(of use: PredicateUse) -> String? {
        guard let base = use.base else {
            return enclosingTypes(at: use.offset).first?.name
        }
        return binding(base, at: use.offset)?.typeText
    }

    // MARK: - Invalidation

    /// True when something may have changed the value `key` names between a
    /// claim and a use of it.
    ///
    /// A change after the use counts too, when both sit in a loop the claim is
    /// outside of: the second iteration runs after the first one's change. A
    /// change written in a closure counts wherever it is written.
    ///
    /// - Parameters:
    ///   - key: The value, as ``FallbackSubjectKey`` names it.
    ///   - names: Every name the value's expression mentions.
    ///   - start: Where the claim was made.
    ///   - use: Where it is relied on.
    func isInvalidated(_ key: String, names: Set<String>, from start: Int, to use: Int) -> Bool {
        let path = Self.leadingPath(of: key)
        let isAboutElement = key.contains("[")
        for name in names {
            for change in changes[name] ?? [] where affects(change, path: path, isAboutElement: isAboutElement) {
                if change.deferredWithin?.contains(use) == true { return true }
                if reaches(change.offset, from: start, to: use) { return true }
            }
        }
        return false
    }

    /// True when `change` could alter the value at `path`.
    ///
    /// A change to `state.a` does not alter `state.b`; a change to `state`
    /// alters both. A change to any other name the value mentions — the `i`
    /// of `r[i]` — alters it.
    private func affects(_ change: Change, path: [String], isAboutElement: Bool) -> Bool {
        if let method = change.method {
            if Self.nonMutatingMethods.contains(method) { return false }
            if change.isOnElement && !isAboutElement { return false }
            if let owner = change.path.first, binding(owner, at: change.offset)?.isImmutable == true { return false }
        }
        guard change.path.first == path.first else { return true }
        let shared = min(change.path.count, path.count)
        return Array(change.path.prefix(shared)) == Array(path.prefix(shared))
    }

    /// The member path a key starts with: `state.totalSteps` from
    /// `state.totalSteps`, `r` from `r[i][i]`.
    static func leadingPath(of key: String) -> [String] {
        let head = key.prefix { $0 != "[" && $0 != "(" }
        return head.split(separator: ".").map(String.init)
    }

    private func reaches(_ change: Int, from start: Int, to use: Int) -> Bool {
        if change > start && change < use { return true }
        guard change >= use else { return false }
        return loops.contains { $0.start > start && $0.contains(use) && $0.contains(change) }
    }

    /// Methods known not to change what they are called on. A call to any
    /// other method, on a name that is not a `let` or a parameter, ends every
    /// claim about that name.
    static let nonMutatingMethods: Set<String> = [
        "map", "compactMap", "flatMap", "filter", "reduce", "forEach", "contains", "allSatisfy",
        "first", "last", "min", "max", "sorted", "reversed", "shuffled", "enumerated", "prefix",
        "suffix", "dropFirst", "dropLast", "joined", "firstIndex", "lastIndex", "index", "split",
        "elementsEqual", "starts", "isMultiple", "rounded", "squareRoot", "magnitude", "distance",
        "advanced", "isLess", "isEqual", "truncatingRemainder", "formatted", "description"
    ]

    /// Calls whose result has as many elements as what they were called on.
    static let countPreservingMethods: Set<String> = [
        "map", "sorted", "reversed", "shuffled", "enumerated"
    ]

    /// Integer type names, with the width each is known to have. `Int` and
    /// `UInt` are 32: that is the least they can be.
    static let integerBits: [String: Int] = [
        "Int": 32, "UInt": 32, "Int8": 8, "UInt8": 8, "Int16": 16, "UInt16": 16,
        "Int32": 32, "UInt32": 32, "Int64": 64, "UInt64": 64
    ]
}
