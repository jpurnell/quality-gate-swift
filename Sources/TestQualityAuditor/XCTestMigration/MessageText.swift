import SwiftSyntax

/// An XCTest failure message, written as a Swift Testing `Comment`.
///
/// XCTest took `@autoclosure () -> String`. `Comment` is a string-literal type, not a `String`,
/// so only a literal passes through unchanged.
enum MessageText {

    /// `expression` as a `Comment` argument.
    ///
    /// - Parameters:
    ///   - expression: The message as written.
    ///   - text: Its converted source.
    /// - Returns: The literal itself; a one-line expression interpolated into a literal; or
    ///   `Comment(rawValue:)` around anything that spans lines.
    ///
    /// The last case is what declined 12 of BusinessMathExcel's 50 files. A message built as
    /// `"first half " + "second half"` across two lines was interpolated into a one-line
    /// literal, which cannot contain a newline, so the converted file did not parse.
    static func comment(_ expression: ExprSyntax, text: String) -> String {
        if expression.is(StringLiteralExprSyntax.self) { return text }
        if text.contains(where: \.isNewline) { return "Comment(rawValue: \(text))" }
        return "\"\\(" + text + ")\""
    }
}
