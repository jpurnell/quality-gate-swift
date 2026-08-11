import Foundation
import QualityGateCore

/// A statement the documentation makes about what its code produces.
///
/// The convention was read off a corpus rather than designed: 95 claims across 13 articles,
/// in three spellings that do not mean the same thing.
///
/// - `// Result:` (85 occurrences) is the **value of the binding above it**. 81 of those
///   bindings are never printed at all, which is why an implementation built on capturing
///   stdout would verify a sixth of this corpus and report success.
/// - `// Output:` (9) is a **transcript of stdout**, quoting the line the `print` above it
///   emits, usually with a parenthetical gloss that is not on stdout.
/// - `// →` (7) is **not a claim** and is deliberately not parsed. Two of the seven give an
///   alternation of possible values (`.strong / .moderate`); five are editorial arrows in
///   prose position. Recognising them would produce seven findings, all false, on the first
///   run — and a gate that is red on arrival with false findings gets switched off.
///
/// The two kinds are kept distinct rather than unified onto one spelling. They anchor to
/// different things and are compared differently, so collapsing them would throw away the
/// only signal in the corpus that says which comparison is meant — and cost 95 edits to do it.
public struct OutputClaim: Sendable, Equatable {

    /// What the claim is about.
    public enum Kind: Sendable, Equatable {

        /// The value of the binding above — `// Result:`.
        case value

        /// A line of stdout — `// Output:`.
        case transcript
    }

    /// What the claim can be checked against.
    public enum Anchor: Sendable, Equatable {

        /// A file-scope `let` or `var` of this name, whose value can be read directly.
        case binding(String)

        /// A file-scope `print`, whose output can be located in stdout.
        case printStatement

        /// Nothing this checker can bind to.
        ///
        /// A `print` nested in a closure or a loop executes an unknown number of times, so
        /// "the next line of stdout" is not well defined without tracking iterations.
        /// Reported and counted, never silently skipped: the gap between claims *found* and
        /// claims *checked* is the whole difference between a coverage number and a fiction.
        case unanchored
    }

    /// The 1-indexed article line the claim is written on.
    public let articleLine: Int

    /// Whether it describes a value or a line of stdout.
    public let kind: Kind

    /// The claim's text, with the marker removed and nothing else changed.
    public let body: String

    /// What it can be checked against.
    public let anchor: Anchor

    /// Whether it sits inside a block the author marked `<!-- docs:illustrative -->`.
    ///
    /// Such a claim is structurally unreachable — the block is not in the assembled program
    /// at all — so it is counted and excluded rather than reported as a failure.
    public let isExempt: Bool

    /// The claim's 1-indexed line in the assembled program, or `0` when it is exempt.
    let assembledLine: Int

    /// The 1-indexed assembled line of the statement it anchors to, or `0`.
    let anchorAssembledLine: Int

    /// Creates a claim.
    init(
        articleLine: Int, kind: Kind, body: String, anchor: Anchor,
        isExempt: Bool, assembledLine: Int, anchorAssembledLine: Int
    ) {
        self.articleLine = articleLine
        self.kind = kind
        self.body = body
        self.anchor = anchor
        self.isExempt = isExempt
        self.assembledLine = assembledLine
        self.anchorAssembledLine = anchorAssembledLine
    }

    /// The marker that opens a claim of each kind, longest first so `Result:` is not matched
    /// as a prefix of something else.
    static let markers: [(prefix: String, kind: Kind)] = [
        ("// Result:", .value),
        ("// Output:", .transcript),
    ]

    /// Reads a claim marker out of one source line.
    ///
    /// Both positions the corpus uses are handled: on its own line under the statement (94
    /// occurrences), and trailing on the code line itself (1). Handling only the first loses
    /// the second in silence.
    ///
    /// - Parameter line: One line of an assembled program.
    /// - Returns: The kind and body, or `nil` when the line carries no claim.
    static func marker(in line: String) -> (kind: Kind, body: String)? {
        for (prefix, kind) in markers {
            guard let range = line.range(of: prefix) else { continue }
            // A claim marker must open a comment: the text before it is either whitespace
            // (own-line) or code that does not already contain `//` (trailing). Anything else
            // is prose about this checker rather than a claim.
            let before = line[line.startIndex..<range.lowerBound]
            guard !before.contains("//") else { continue }
            return (kind, String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// What a claim's text turned out to say.
public enum ClaimBody: Sendable, Equatable {

    /// A single number, and how far from it a measurement may fall.
    case scalar(Double, tolerance: Double)

    /// A sequence of numbers, each with its own tolerance.
    ///
    /// Elementwise, because the documented precision differs per element:
    /// `[0.1, 0.12, 0.115]` claims one, two and three decimal places in turn.
    case sequence([Double], tolerances: [Double])

    /// Commentary rather than a value.
    ///
    /// 28 of 99 claims in the measured corpus. `// Result: Approaches but never exceeds
    /// 25,000` is a true and useful statement that no comparator will ever evaluate, and
    /// reporting the count is what keeps "claims checked" from being mistaken for "claims
    /// made".
    case prose

    /// Parses a claim's text.
    ///
    /// ## The tolerance comes from the documented literal's own precision
    ///
    /// Half a unit in the last place written. `100,000` claims six significant digits, so the
    /// assertion is `|actual − 100000| < 0.5` — which passes on `99999.99999999999` and fails
    /// on `100,001`. This is not an invention; it is what a reader already assumes when they
    /// see a rounded figure, made explicit. It is also self-tightening: an author who wants a
    /// stricter check writes more digits.
    ///
    /// A leading `~` or `≈` — which 48 of 99 claims already carry — widens that to two units
    /// in the last written place. The corpus has been distinguishing approximate from exact
    /// all along, in its own notation, and nobody was reading it. It widens rather than
    /// disables, because an author writing `~` means "about this", not "any number".
    ///
    /// - Parameter body: The claim's text, marker already removed.
    /// - Returns: The parsed value, or ``prose`` when it is not one.
    public static func parse(_ body: String) -> ClaimBody {
        var text = strippingGloss(body)
        var widened = false

        while let first = text.first, first == "~" || first == "≈" {
            widened = true
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        let widening = widened ? 4.0 : 1.0

        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            guard !inner.trimmingCharacters(in: .whitespaces).isEmpty else { return .prose }
            var values: [Double] = []
            var tolerances: [Double] = []
            for element in inner.components(separatedBy: ",") {
                guard let number = number(in: element) else { return .prose }
                values.append(number.value)
                tolerances.append(number.tolerance * widening)
            }
            return .sequence(values, tolerances: tolerances)
        }

        guard let number = number(in: text) else { return .prose }
        return .scalar(number.value, tolerance: number.tolerance * widening)
    }

    /// Removes the glosses the corpus attaches to claims.
    ///
    /// Two shapes, both measured. A trailing parenthetical — 33 of 99 own-line claims carry
    /// one — is an aside, never part of the value and never on stdout:
    /// `Price: $1,043.30 (trades at premium since coupon > yield)`. An em-dash continuation
    /// is the same thing in a different hand: `[0.1, 0.12, 0.115] — the same revenue restated
    /// in thousands`.
    ///
    /// Neither can change a number, which is why stripping them is safe. What they *can* do
    /// is turn a value claim into an unparseable one, and every such claim is a number that
    /// silently stops being checked.
    static func strippingGloss(_ body: String) -> String {
        var text = body.trimmingCharacters(in: .whitespaces)

        for separator in [" — ", " – ", " -- "] {
            if let range = text.range(of: separator) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }

        if text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) {
            text = String(text[text.startIndex..<open.lowerBound])
        }

        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Magnitude suffixes a documented figure may carry, and what they multiply it by.
    ///
    /// Closed on purpose. An open rule — "any adjacent letters are a unit" — reads `$57.7M`
    /// as `57.7`, and the resulting finding accuses documentation that was right.
    static let magnitudes: [String: Double] = [
        "k": 1_000, "m": 1_000_000, "mm": 1_000_000,
        "b": 1_000_000_000, "bn": 1_000_000_000,
    ]

    /// Reads one number, with its documented precision, out of a claim element.
    ///
    /// Accepts the notation the corpus writes numbers in — a `$` prefix, `,` group
    /// separators, a `k` thousands suffix, a `%` suffix — and a trailing unit phrase made
    /// only of words (`per month`, `periods`, `CAGR`). A unit cannot change the value, so
    /// stripping one is safe; rejecting it would discard a real number to avoid a decision.
    ///
    /// A `%` is read as the unit it is: the documentation writes a percentage where the
    /// library returns a fraction, so both the value and its tolerance are divided by 100.
    /// Comparing the two without converting fails every correct rate in the corpus.
    ///
    /// - Returns: The value in the code's own units and the tolerance implied by the digits
    ///   written, or `nil` when the text does not open with a number.
    static func number(in text: String) -> (value: Double, tolerance: Double)? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return nil }

        var sign = 1.0
        if rest.hasPrefix("-") {
            sign = -1
            rest = rest.dropFirst()
        } else if rest.hasPrefix("+") {
            rest = rest.dropFirst()
        }
        if rest.hasPrefix("$") { rest = rest.dropFirst() }

        var digits = ""
        var decimals = 0
        var seenPoint = false
        while let character = rest.first {
            if character.isNumber {
                digits.append(character)
                if seenPoint { decimals += 1 }
            } else if character == "," && !seenPoint {
                // A group separator, not a delimiter — the list case already split on commas
                // at the top level before reaching here.
            } else if character == "." && !seenPoint {
                // A full stop that closes a sentence is not a decimal point. Only treat it as
                // one when a digit follows.
                guard rest.dropFirst().first?.isNumber == true else { break }
                seenPoint = true
                digits.append(".")
            } else {
                break
            }
            rest = rest.dropFirst()
        }

        guard !digits.isEmpty, let magnitude = Double(digits) else { return nil }
        var value = sign * magnitude
        // Divided rather than multiplied by a reciprocal throughout, so the tolerance is the
        // correctly-rounded double nearest the decimal the author wrote. `0.5 * 1e-4` and
        // `0.5 / 1e4` are not the same double, and the difference is a claim that passes on
        // one machine's arithmetic and fails on the next.
        // Guarded rather than divided blind. `decimals` comes from a document, and a claim
        // written with a few hundred decimal places overflows `pow` to infinity — after which
        // the tolerance is exactly zero and every comparison against it fails, which is a
        // wrong finding rather than an absent one. An unrepresentable precision is a claim
        // this parser cannot hold anyone to.
        let place = pow(10.0, Double(decimals))
        guard place.isFinite, place > 0 else { return nil }
        var tolerance = 0.5 / place

        // A letter run *adjacent* to the digits is a magnitude, and it must be one this
        // parser knows. Treating it as the start of a unit phrase — as an earlier version did
        // — silently drops it: `$57.7M` reads as `57.7`, and the checker then accuses correct
        // documentation of publishing 57.7 where the code produced 57,665,039. A checker
        // whose authority rests on its findings being true cannot afford that, so an
        // unrecognised adjacent suffix makes the claim not-comparable rather than wrong.
        let adjacent = rest.prefix { $0.isLetter }
        if !adjacent.isEmpty {
            guard let multiplier = magnitudes[adjacent.lowercased()] else { return nil }
            value *= multiplier
            tolerance *= multiplier
            rest = rest.dropFirst(adjacent.count)
        }

        if rest.hasPrefix("%") {
            value /= 100
            tolerance /= 100
            rest = rest.dropFirst()
        }

        // Whatever is left is a unit phrase — separated from the number by a space or a
        // slash, so it cannot be confused with a magnitude. A unit cannot change the value,
        // which is why dropping one is safe; anything else means the text was prose that
        // happened to open with a digit.
        let trailing = rest.trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || rest.first == " " || rest.first == "/" else { return nil }
        let isUnit = trailing.allSatisfy { $0.isLetter || $0.isWhitespace || $0 == "/" || $0 == "." }
        guard isUnit else { return nil }

        return (value, tolerance)
    }
}
