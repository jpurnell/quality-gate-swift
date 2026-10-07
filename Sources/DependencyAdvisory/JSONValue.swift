import Foundation
import QualityGateCore

// An advisory snapshot holds OSV records **verbatim**, so that a reviewer can diff a refresh and
// see an advisory arrive. A typed model would keep only the fields this checker reads and
// silently drop the rest on the next write. `JSONValue` — the type the plugin contract already
// uses for JSON the host does not interpret — keeps all of it, and `Advisory` is the typed view
// taken over the top for matching.

extension JSONValue {

    /// The member named `key`, when this is an object that has one.
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    /// The text, when this is a string.
    var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    /// The elements, when this is an array; otherwise none.
    var arrayValue: [JSONValue] {
        guard case .array(let elements) = self else { return [] }
        return elements
    }
}

extension JSONValue {

    /// The value as compact JSON with object keys sorted — one byte sequence per value.
    ///
    /// The snapshot's `contentHash` is taken over this, not over the file's bytes, because the
    /// file is written by `JSONEncoder` and its escaping and number formatting are Foundation's
    /// to change between releases and between Darwin and Linux. This form is written here, so it
    /// is the same everywhere, and it is the form RFC 8785 (JCS) specifies for strings and
    /// structure: keys in code-unit order, no whitespace, `/` unescaped, `"` and `\` escaped,
    /// the five short escapes, and `\u00xx` for the other C0 controls. So the hash can be
    /// reproduced without this code:
    /// `json.dumps(records, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`.
    var canonicalJSON: String {
        var out = ""
        appendCanonical(to: &out)
        return out
    }

    private func appendCanonical(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value): out += Self.canonicalNumber(value)
        case .string(let value): Self.appendQuoted(value, to: &out)
        case .array(let elements): Self.appendArray(elements, to: &out)
        case .object(let members): Self.appendObject(members, to: &out)
        }
    }

    /// A whole number is written without a fraction, so `1` in a record hashes as `1` and not
    /// as the `1.0` a `Double` would print. The Swift export holds no numbers at all today.
    private static func canonicalNumber(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { // 2^53: exactly representable
            return String(Int64(value))
        }
        return "\(value)"
    }

    private static func appendArray(_ elements: [JSONValue], to out: inout String) {
        out += "["
        for (index, element) in elements.enumerated() {
            if index > 0 { out += "," }
            element.appendCanonical(to: &out)
        }
        out += "]"
    }

    private static func appendObject(_ members: [String: JSONValue], to out: inout String) {
        out += "{"
        // Ordered by UTF-8 code units rather than by `String`'s `<`, which compares by
        // extended grapheme cluster and is therefore a property of the Unicode tables in use.
        let ordered = members.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
        for (index, member) in ordered.enumerated() {
            if index > 0 { out += "," }
            appendQuoted(member.key, to: &out)
            out += ":"
            member.value.appendCanonical(to: &out)
        }
        out += "}"
    }

    private static let hexDigits = Array("0123456789abcdef")

    private static func appendQuoted(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                out += "\\u00"
                out.append(hexDigits[Int(scalar.value >> 4)])
                out.append(hexDigits[Int(scalar.value & 0x0F)])
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
