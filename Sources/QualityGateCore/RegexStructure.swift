import Foundation

/// The structure of a regular-expression pattern, read far enough to find the two shapes that
/// make a backtracking engine exponential (`APatternIsAProgram.md` §4.1).
///
/// SwiftSyntax hands a pattern over as a string; this reads the string — groups, character
/// classes, escapes, quantifiers, alternation — in ICU syntax, which is what both
/// `NSRegularExpression` and, at the edges this needs, Swift `Regex` accept. It has no dependency
/// on a syntax tree so that a configuration loader can call it on a pattern read from YAML.
///
/// ## What is flagged
///
/// A group quantified by `+`, `*` or `{n,}` (not possessive, not atomic) is reported when:
///
/// - **(a) nested repetition** — one of its alternatives holds, at its top level, an atom
///   quantified by `+`, `*` or `{n,}` that is not possessive, and **no mandatory literal**: an
///   unquantified (or `{n}` / `{n,m}` with *n* ≥ 1) literal character such as the `,` in
///   `(\d+,)*` or the `\.` in `(?:\.\d+)*`. Each repetition then has to consume a character the
///   inner quantifier cannot, which is what keeps those linear.
/// - **(b) overlapping alternation** — two of its alternatives are identical, one is a literal
///   prefix of the other, or both are single characters from classes known to overlap (`.` with
///   anything; `\w` with `\d`; a literal with a class that contains it).
///
/// ## What is not
///
/// Polynomial shapes (`\d+(?:\.\d+)*$` on a long digit run; `.*.*=`), overlap behind a separator
/// (`(a+a)*`), and anything the pattern does only on some engine. A malformed pattern yields no
/// finding — compiling it is the engine's business.
///
/// ## Usage
///
/// ```swift
/// for finding in RegexStructure.catastrophicGroups(in: #"^(\w+\s?)*$"#) {
///     // nestedRepetition (\w+\s?)*
///     print(finding.shape, finding.group)
/// }
/// ```
public enum RegexStructure {

    /// Stands for a value interpolated into a pattern: an atom that is neither a literal nor a
    /// repetition. A caller replaces each interpolation with it before asking.
    public static let opaqueAtom: Character = "\u{E000}"

    /// The two catastrophic shapes.
    public enum Shape: String, Sendable, Hashable {
        /// A repeated group whose body repeats without a separator: `(a+)+`.
        case nestedRepetition
        /// A repeated group whose alternatives can match the same text: `(a|ab)+`.
        case overlappingAlternation
    }

    /// One catastrophic group.
    public struct Finding: Sendable, Hashable {
        /// Which shape it has.
        public let shape: Shape
        /// The group and its quantifier, as written: `(a+)+`.
        public let group: String

        /// Creates a finding.
        public init(shape: Shape, group: String) {
            self.shape = shape
            self.group = group
        }
    }

    /// Every catastrophic group in `pattern`, in source order; empty for a malformed pattern.
    public static func catastrophicGroups(in pattern: String) -> [Finding] {
        var parser = PatternParser(Array(pattern))
        guard let items = parser.parseAll() else { return [] }
        var findings: [Finding] = []
        var pending: [[Item]] = [items]
        // Breadth by sequence, depth-first overall; the order of `pending` keeps source order.
        while !pending.isEmpty {
            let sequence = pending.removeFirst()
            var nested: [[Item]] = []
            for item in sequence {
                guard case .group(let group) = item.atom else { continue }
                if let shape = shape(of: group, quantifier: item.quantifier) {
                    findings.append(Finding(shape: shape, group: item.text))
                }
                nested.append(contentsOf: group.alternatives)
            }
            pending.insert(contentsOf: nested, at: 0)
        }
        return findings
    }

    // MARK: - The model

    /// A quantifier: `{min, max}`, `max == nil` for unbounded.
    struct Quantifier: Equatable {
        let min: Int
        let max: Int?
        let possessive: Bool

        var isUnbounded: Bool { max == nil }
    }

    enum GroupKind: Equatable {
        case capturing, nonCapturing, atomic, lookaround
    }

    struct Group: Equatable {
        let kind: GroupKind
        let alternatives: [[Item]]
    }

    indirect enum Atom: Equatable {
        /// One literal character, escaped or not.
        case literal(Character)
        /// A set of characters: `.`, `\d`, `[a-z]`, as written.
        case characterClass(String)
        /// Zero-width: `^`, `$`, `\b`, inline flags.
        case anchor
        /// A back-reference or an interpolation: unknown text.
        case opaque
        case group(Group)
    }

    struct Item: Equatable {
        let atom: Atom
        let quantifier: Quantifier?
        let text: String

        var isUnboundedRepetition: Bool {
            guard let quantifier, quantifier.isUnbounded, !quantifier.possessive else { return false }
            if case .anchor = atom { return false }
            return true
        }

        var isMandatoryLiteral: Bool {
            guard case .literal = atom else { return false }
            guard let quantifier else { return true }
            return quantifier.min >= 1 && !quantifier.isUnbounded
        }
    }

    // MARK: - Shapes

    static func shape(of group: Group, quantifier: Quantifier?) -> Shape? {
        guard let quantifier, quantifier.isUnbounded, !quantifier.possessive,
              group.kind == .capturing || group.kind == .nonCapturing else { return nil }
        let nested = group.alternatives.contains { alternative in
            alternative.contains(where: \.isUnboundedRepetition) && !alternative.contains(where: \.isMandatoryLiteral)
        }
        if nested { return .nestedRepetition }
        return overlaps(group.alternatives) ? .overlappingAlternation : nil
    }

    static func overlaps(_ alternatives: [[Item]]) -> Bool {
        guard alternatives.count > 1 else { return false }
        for (index, first) in alternatives.enumerated() {
            for second in alternatives[(index + 1)...] where overlap(first, second) {
                return true
            }
        }
        return false
    }

    private static func overlap(_ first: [Item], _ second: [Item]) -> Bool {
        let firstText = first.map(\.text).joined()
        let secondText = second.map(\.text).joined()
        if !firstText.isEmpty, firstText == secondText { return true }
        if let left = literalText(first), let right = literalText(second), !left.isEmpty, !right.isEmpty,
           left.hasPrefix(right) || right.hasPrefix(left) {
            return true
        }
        guard first.count == 1, second.count == 1, first[0].quantifier == nil, second[0].quantifier == nil else {
            return false
        }
        return charactersOverlap(first[0].atom, second[0].atom)
    }

    /// The text of an alternative made only of unquantified literal characters.
    private static func literalText(_ items: [Item]) -> String? {
        var text = ""
        for item in items {
            guard item.quantifier == nil, case .literal(let character) = item.atom else { return nil }
            text.append(character)
        }
        return text
    }

    private static func charactersOverlap(_ first: Atom, _ second: Atom) -> Bool {
        switch (first, second) {
        case (.characterClass("."), .characterClass), (.characterClass("."), .literal),
             (.characterClass, .characterClass(".")), (.literal, .characterClass(".")):
            return true
        case (.characterClass(let left), .characterClass(let right)):
            let pair: Set<String> = [left, right]
            return left == right || pair == [#"\w"#, #"\d"#]
        case (.characterClass(let set), .literal(let character)), (.literal(let character), .characterClass(let set)):
            return classContains(set, character)
        default:
            return false
        }
    }

    private static func classContains(_ set: String, _ character: Character) -> Bool {
        switch set {
        case #"\d"#: return character.isASCII && character.isNumber
        case #"\w"#: return character == "_" || (character.isASCII && (character.isLetter || character.isNumber))
        case #"\s"#: return character.isWhitespace
        default: return false
        }
    }
}

// MARK: - Parsing

/// A recursive-descent reader of ICU pattern syntax, as much as the shapes need.
///
/// Nesting is bounded by ``maximumDepth``; past it the pattern is treated as malformed.
struct PatternParser {
    typealias Item = RegexStructure.Item
    typealias Atom = RegexStructure.Atom

    static let maximumDepth = 64
    static let classEscapes: Set<Character> = ["d", "D", "w", "W", "s", "S", "h", "H", "v", "V", "R", "X"]
    static let anchorEscapes: Set<Character> = ["b", "B", "A", "z", "Z", "G"]
    static let controlEscapes: [Character: Character] = ["t": "\t", "n": "\n", "r": "\r", "f": "\u{0C}", "a": "\u{07}", "e": "\u{1B}"]

    let characters: [Character]
    var index = 0

    init(_ characters: [Character]) {
        self.characters = characters
    }

    /// The whole pattern as one sequence of items, or `nil` if it is malformed.
    mutating func parseAll() -> [Item]? {
        guard let alternatives = parseAlternatives(depth: 0), index == characters.count else { return nil }
        // A top-level alternation is examined as a group nobody quantified.
        guard alternatives.count > 1 else { return alternatives.first ?? [] }
        return alternatives.flatMap { $0 }
    }

    private var current: Character? { index < characters.count ? characters[index] : nil }

    private func peek(_ offset: Int) -> Character? {
        index + offset < characters.count ? characters[index + offset] : nil
    }

    private func text(from start: Int) -> String {
        String(characters[start..<index])
    }

    mutating func parseAlternatives(depth: Int) -> [[Item]]? {
        guard depth < Self.maximumDepth else { return nil }
        var alternatives: [[Item]] = []
        var sequence: [Item] = []
        while let character = current, character != ")" {
            if character == "|" {
                alternatives.append(sequence)
                sequence = []
                index += 1
                continue
            }
            guard let items = parseItem(depth: depth) else { return nil }
            sequence.append(contentsOf: items)
        }
        alternatives.append(sequence)
        return alternatives
    }

    /// One atom and its quantifier; zero items for a comment or flags, several for `\Q…\E`.
    private mutating func parseItem(depth: Int) -> [Item]? {
        let start = index
        guard let atoms = parseAtom(depth: depth) else { return nil }
        guard atoms.count == 1, let atom = atoms.first else {
            return atoms.map { Item(atom: $0, quantifier: nil, text: "") }
        }
        let quantifier = parseQuantifier()
        return [Item(atom: atom, quantifier: quantifier, text: text(from: start))]
    }

    private mutating func parseAtom(depth: Int) -> [Atom]? {
        guard let character = current else { return nil }
        switch character {
        case "(":
            return parseGroup(depth: depth)
        case "[":
            return parseClass().map { [$0] }
        case "\\":
            return parseEscape()
        case "*", "+", "?":
            return nil
        case ".":
            index += 1
            return [.characterClass(".")]
        case "^", "$":
            index += 1
            return [.anchor]
        case RegexStructure.opaqueAtom:
            index += 1
            return [.opaque]
        default:
            index += 1
            return [.literal(character)]
        }
    }

    private mutating func parseGroup(depth: Int) -> [Atom]? {
        index += 1 // (
        var kind = RegexStructure.GroupKind.capturing
        if current == "?" {
            index += 1
            switch current {
            case ":": index += 1; kind = .nonCapturing
            case ">": index += 1; kind = .atomic
            case "=", "!": index += 1; kind = .lookaround
            case "#":
                while let character = current, character != ")" { index += 1 }
                guard current == ")" else { return nil }
                index += 1
                return []
            case "<" where peek(1) == "=" || peek(1) == "!":
                index += 2; kind = .lookaround
            case "<", "P", "'":
                guard skipGroupName() else { return nil }
            default:
                // Inline flags: `(?i)` is zero-width; `(?i:…)` is a non-capturing group.
                while let character = current, character.isLetter || character == "-" { index += 1 }
                if current == ")" {
                    index += 1
                    return [.anchor]
                }
                guard current == ":" else { return nil }
                index += 1
                kind = .nonCapturing
            }
        }
        guard let alternatives = parseAlternatives(depth: depth + 1), current == ")" else { return nil }
        index += 1
        return [.group(RegexStructure.Group(kind: kind, alternatives: alternatives))]
    }

    private mutating func skipGroupName() -> Bool {
        if current == "P" { index += 1 }
        guard let open = current else { return false }
        let close: Character = open == "'" ? "'" : ">"
        index += 1
        while let character = current, character != close { index += 1 }
        guard current == close else { return false }
        index += 1
        return true
    }

    private mutating func parseClass() -> Atom? {
        let start = index
        index += 1 // [
        if current == "^" { index += 1 }
        if current == "]" { index += 1 }
        var depth = 1
        while let character = current {
            index += 1
            if character == "\\" {
                index += 1
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 { return .characterClass(text(from: start)) }
            }
        }
        return nil
    }

    private mutating func parseEscape() -> [Atom]? {
        index += 1 // backslash
        guard let character = current else { return nil }
        index += 1
        if Self.classEscapes.contains(character) {
            return [.characterClass("\\\(character)")]
        }
        if Self.anchorEscapes.contains(character) {
            return [.anchor]
        }
        if let control = Self.controlEscapes[character] {
            return [.literal(control)]
        }
        switch character {
        case "p", "P":
            if current == "{" { skip(past: "}") } else { index += 1 }
            return [.characterClass("\\\(character)")]
        case "1"..."9":
            while let digit = current, digit.isNumber { index += 1 }
            return [.opaque]
        case "k":
            skip(past: ">")
            return [.opaque]
        case "x", "N":
            if current == "{" { skip(past: "}") } else { index = min(index + 2, characters.count) }
            return [.literal(character)]
        case "u":
            index = min(index + 4, characters.count)
            return [.literal(character)]
        case "Q":
            return quotedLiterals()
        default:
            return [.literal(character)]
        }
    }

    private mutating func skip(past terminator: Character) {
        while let character = current {
            index += 1
            if character == terminator { return }
        }
    }

    /// `\Q…\E`: every character literal.
    private mutating func quotedLiterals() -> [Atom] {
        var atoms: [Atom] = []
        while let character = current {
            if character == "\\", peek(1) == "E" {
                index += 2
                return atoms
            }
            atoms.append(.literal(character))
            index += 1
        }
        return atoms
    }

    private mutating func parseQuantifier() -> RegexStructure.Quantifier? {
        guard let character = current else { return nil }
        let bounds: (Int, Int?)
        switch character {
        case "*": index += 1; bounds = (0, nil)
        case "+": index += 1; bounds = (1, nil)
        case "?": index += 1; bounds = (0, 1)
        case "{":
            guard let braced = parseBraces() else { return nil }
            bounds = braced
        default:
            return nil
        }
        var possessive = false
        if current == "+" {
            possessive = true
            index += 1
        } else if current == "?" {
            index += 1
        }
        return RegexStructure.Quantifier(min: bounds.0, max: bounds.1, possessive: possessive)
    }

    /// `{n}`, `{n,}`, `{n,m}`; anything else leaves `{` to be read as a literal.
    private mutating func parseBraces() -> (Int, Int?)? {
        var cursor = index + 1
        var lower = ""
        while cursor < characters.count, characters[cursor].isNumber {
            lower.append(characters[cursor])
            cursor += 1
        }
        guard let minimum = Int(lower), cursor < characters.count else { return nil }
        if characters[cursor] == "}" {
            index = cursor + 1
            return (minimum, minimum)
        }
        guard characters[cursor] == "," else { return nil }
        cursor += 1
        var upper = ""
        while cursor < characters.count, characters[cursor].isNumber {
            upper.append(characters[cursor])
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "}" else { return nil }
        index = cursor + 1
        return (minimum, Int(upper))
    }
}
