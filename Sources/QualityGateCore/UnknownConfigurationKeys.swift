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
    /// - Parameters:
    ///   - written: The key found in the file.
    ///   - known: Keys the schema defines.
    /// - Returns: The nearest key, or `nil` when nothing is close.
    public static func nearestKey(to written: String, in known: Set<String>) -> String? {
        let lowered = written.lowercased()
        // A containment match first: `checkers` inside `enabledCheckers` is a stronger
        // signal than any edit distance, and edit distance alone would not find it —
        // the two differ by seven characters.
        let contained = known
            .filter { $0.lowercased().contains(lowered) || lowered.contains($0.lowercased()) }
            .sorted { $0.count < $1.count }
        if let best = contained.first { return best }

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
    /// - Returns: The error, or `nil` when every key is known.
    public static func check(present: Set<String>, known: Set<String>) -> UnknownConfigurationKeys? {
        let unknown = present.subtracting(known).sorted()
        guard !unknown.isEmpty else { return nil }
        return UnknownConfigurationKeys(
            keys: unknown,
            suggestions: unknown.compactMap { key in
                nearestKey(to: key, in: known).map { (written: key, suggested: $0) }
            })
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
