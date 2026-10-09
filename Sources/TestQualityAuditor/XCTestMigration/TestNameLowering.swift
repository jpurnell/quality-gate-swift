/// `testFooBar` → `fooBar`, or `nil` where that would not be a usable name.
///
/// Swift Testing names a test by its function, and the `test` prefix was only ever XCTest's
/// discovery mechanism. But the prefix is also what kept `testRepeat` from being the keyword
/// `repeat`, so a lowered name that is a keyword is refused and the caller keeps the original.
/// That is the case the SwiftExcelFunctions migration hit, as a compile error on a
/// three-letter test.
enum TestNameLowering {

    /// The lowered name, or `nil` when it would be empty, start with a digit, or be a keyword.
    static func lowered(_ name: String) -> String? {
        guard name.hasPrefix("test") else { return nil }
        var rest = Substring(name.dropFirst(4))
        while rest.first == "_" { rest = rest.dropFirst() }
        guard let first = rest.first, !first.isNumber else { return nil }

        let lowered = lowerLeadingWord(String(rest))
        return keywords.contains(lowered) ? nil : lowered
    }

    /// Lowers the leading capital, or a leading acronym as one word: `URLParses` → `urlParses`,
    /// `AThing` → `aThing`.
    static func lowerLeadingWord(_ text: String) -> String {
        let characters = Array(text)
        var capitals = 0
        while capitals < characters.count, characters[capitals].isUppercase { capitals += 1 }
        guard capitals > 0 else { return text }
        // In `URLParses` the run is `URLP`; its last capital starts the next word.
        let followedByLowercase = capitals < characters.count && characters[capitals].isLowercase
        let lowerCount = capitals > 1 && followedByLowercase ? capitals - 1 : capitals
        return String(characters[..<lowerCount]).lowercased() + String(characters[lowerCount...])
    }

    /// Words that cannot name a function without backticks.
    static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "open", "operator", "private", "precedencegroup",
        "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var",
        "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough",
        "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while",
        "Any", "as", "await", "false", "is", "nil", "self", "Self", "super", "throws", "true",
        "try", "async", "consume", "copy", "discard", "each", "some", "any",
    ]
}
