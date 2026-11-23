import Foundation

/// A configuration key present in the file that the schema does not define.
///
/// ## Why an unknown key is an error rather than a shrug
///
/// `Configuration` decodes every field with `decodeIfPresent(…) ?? default`, so a key
/// outside `CodingKeys` is not an error, not a warning, not a note — it is discarded
/// during decoding and nothing downstream can tell it was ever written.
///
/// BusinessMath carried five top-level keys and two were fiction. The one that
/// mattered was `checkers:` where the schema says `enabledCheckers`. The file read as
/// *run everything*; the decoder saw no `enabledCheckers`, left it empty, and checker
/// selection fell through to a default that opts out of several checkers. **That
/// repository ran 35 checkers on every invocation while its configuration claimed 42**,
/// for as long as the file existed.
///
/// `recursion` was among the seven never run — the checker whose entire purpose is
/// finding unbounded recursion, in a repository whose recursive-descent parser had two
/// unbounded paths reachable from a public API with input that is merely long. A stack
/// overflow cannot be caught. The check was never declined; it was never run.
///
/// ## Why this is worse than an ordinary wrong setting
///
/// A misconfiguration that *does* something is self-correcting: the run looks wrong and
/// someone opens the config. This one is invisible in both directions. The file is not
/// evidence of what the gate does, and a 35-checker run prints the same `PASSED` as a
/// 42-checker run. Nothing in the output is a function of the configuration having been
/// understood.
public struct UnknownConfigurationKeys: Error, Equatable, Sendable {

    /// The keys the schema does not define, sorted.
    public let keys: [String]

    /// Near misses, as `(written, suggested)` pairs.
    public let suggestions: [(written: String, suggested: String)]

    /// Creates the error.
    public init(keys: [String], suggestions: [(written: String, suggested: String)]) {
        self.keys = keys
        self.suggestions = suggestions
    }

    /// Equality over the keys and their suggestions, since tuples are not `Equatable`.
    public static func == (lhs: UnknownConfigurationKeys, rhs: UnknownConfigurationKeys) -> Bool {
        lhs.keys == rhs.keys
            && lhs.suggestions.map(\.written) == rhs.suggestions.map(\.written)
            && lhs.suggestions.map(\.suggested) == rhs.suggestions.map(\.suggested)
    }

    /// The message shown at startup.
    public var message: String {
        var lines = [
            "`.quality-gate.yml` sets \(keys.count) key\(keys.count == 1 ? "" : "s") "
                + "this version does not recognise."
        ]
        let suggested = Dictionary(
            suggestions.map { ($0.written, $0.suggested) }, uniquingKeysWith: { first, _ in first })
        for key in keys {
            if let nearest = suggested[key] {
                lines.append("  · `\(key)` — did you mean `\(nearest)`?")
            } else {
                lines.append("  · `\(key)`")
            }
        }
        lines.append(
            "Unknown keys are not applied. Remove them, or correct them, before the gate "
                + "can say what it checked.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Suggestions

    /// The nearest known key, when one is close enough to be worth naming.
    ///
    /// Both real cases were one substring from a valid key — `checkers` for
    /// `enabledCheckers`, `exclude` for `excludePatterns` — which is the shape a human
    /// typo takes. The distance bound is deliberately tight: **no suggestion is better
    /// than a wrong one**, because a wrong suggestion sends the reader to edit a key
    /// that was never the problem.
    ///
    /// A documented, exact rename, checked before any string-similarity heuristic.
    ///
    /// `exclude` is a real incident, not a hypothetical: it is a prefix of two real top-level keys,
    /// `excludedCheckers` (what it was renamed to) and `excludePatterns` (an unrelated key that holds file globs).
    /// Both contain `exclude` as a substring, so a containment match sees two equally strong candidates and
    /// `excludePatterns` is one character shorter — the wrong one, and the exact trap this schema's own
    /// `.quality-gate.yml` convention comment warns about ("that key holds file globs, so taking the suggestion
    /// turns a checker name into a pattern that matches nothing and excludes nothing"). Edit distance does not
    /// resolve it either: `excludePatterns` is one edit closer to `exclude` than `excludedCheckers` is. Only the
    /// rename's own history disambiguates it, so it is named here rather than left to a heuristic to guess.
    static let documentedRenames: [String: String] = [
        "exclude": "excludedCheckers",
        "checkers": "enabledCheckers",
    ]

    /// - Parameters:
    ///   - written: The key found in the file.
    ///   - known: Keys the schema defines.
    /// - Returns: The nearest key, or `nil` when nothing is close.
    public static func nearestKey(to written: String, in known: Set<String>) -> String? {
        let lowered = written.lowercased()
        if let renamed = documentedRenames[lowered], known.contains(renamed) { return renamed }

        // A containment match next: `checkers` inside `enabledCheckers` is a stronger
        // signal than any edit distance, and edit distance alone would not find it —
        // the two differ by seven characters. Ties (more than one candidate contains, or is
        // contained by, `written`) are refused rather than guessed at by length: see
        // `documentedRenames` above for why a shorter match is not always the right one.
        let contained = known
            .filter { $0.lowercased().contains(lowered) || lowered.contains($0.lowercased()) }
            .sorted { $0.count < $1.count }
        if contained.count == 1 { return contained[0] }
        if contained.count > 1 { return nil }

        let scored = known
            .map { (key: $0, distance: editDistance(lowered, $0.lowercased())) }
            .filter { $0.distance <= max(2, written.count / 3) }
            .sorted { ($0.distance, $0.key) < ($1.distance, $1.key) }
        return scored.first?.key
    }

    /// Levenshtein distance, iterative and allocation-light.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let first = Array(a), second = Array(b)
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }
        var previous = Array(0...second.count)
        var current = [Int](repeating: 0, count: second.count + 1)
        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let substitution = previous[j - 1] + (first[i - 1] == second[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[second.count]
    }

    /// Builds the error for a set of keys found in a file.
    ///
    /// - Parameters:
    ///   - present: Keys the file contains.
    ///   - known: Keys the schema defines.
    ///   - section: The section these keys belong to (`"status"`, `"consistency"`, `"ijs"`), so a key from a
    ///     nested section reads unambiguously once several sections' findings are merged (``merge(_:)``).
    ///     `nil` for the top level.
    /// - Returns: The error, or `nil` when every key is known.
    public static func check(present: Set<String>, known: Set<String>, section: String? = nil) -> UnknownConfigurationKeys? {
        let unknown = present.subtracting(known).sorted()
        guard !unknown.isEmpty else { return nil }
        func qualified(_ key: String) -> String {
            guard let section else { return key }
            return "\(section).\(key)"
        }
        return UnknownConfigurationKeys(
            keys: unknown.map(qualified),
            suggestions: unknown.compactMap { key in
                nearestKey(to: key, in: known).map { (written: qualified(key), suggested: qualified($0)) }
            })
    }

    /// Combines every section's findings into one. `Configuration` has one `unknownKeys` property; this is how a
    /// top-level finding and three nested sections' findings (``StatusAuditorConfig``, ``ConsistencyCheckerConfig``,
    /// ``IJSConfig``) become the single value it reports.
    ///
    /// - Parameter all: one entry per section checked, in the order its keys should be listed.
    /// - Returns: the merged error, or `nil` when every section found nothing.
    public static func merge(_ all: [UnknownConfigurationKeys?]) -> UnknownConfigurationKeys? {
        let present = all.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return UnknownConfigurationKeys(
            keys: present.flatMap(\.keys),
            suggestions: present.flatMap(\.suggestions))
    }
}

/// A coding key that accepts any name, so a container can be asked what it actually holds.
///
/// `Decoder.allKeys` only yields keys that map onto the `CodingKey` type it was opened
/// with, so a container keyed by the schema's own enum can never report a key outside
/// it — which is precisely why the unknown keys were invisible.
public struct AnyCodingKey: CodingKey, Sendable {

    /// The key's name as written in the file.
    public var stringValue: String

    /// The key's integer position, when the container is an array.
    public var intValue: Int?

    /// Creates a key from any name. Never fails.
    public init?(stringValue: String) { self.stringValue = stringValue }

    /// Creates a key from an index. Never fails.
    public init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
}
