import Foundation

/// UTF-16 text with line lookup, the shape `NSRegularExpression` offsets come in.
struct CSSSource: Sendable {
    let units: [UInt16]
    private let lineStarts: [Int]

    init(_ text: String) {
        units = Array(text.utf16)
        var starts = [0]
        for (index, unit) in units.enumerated() where unit == 0x0A { starts.append(index + 1) }
        lineStarts = starts
    }

    var text: String { String(decoding: units, as: UTF16.self) }

    /// One-based line and column of a UTF-16 offset.
    func location(of offset: Int) -> (line: Int, column: Int) {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return (low + 1, offset - lineStarts[low] + 1)
    }
}

enum CSSText {

    /// `css` with every `/* ... */` comment blanked to spaces; newlines are kept, so offsets and
    /// line numbers of everything else are unchanged.
    static func strippingComments(_ css: String) -> String {
        blanking(css, open: "/*", close: "*/")
    }

    /// Blanks each `open ... close` span to spaces, keeping newlines. An unterminated span runs
    /// to the end of the text.
    static func blanking(_ text: String, open: String, close: String) -> String {
        var units = Array(text.utf16)
        let opening = Array(open.utf16)
        let closing = Array(close.utf16)
        var index = 0
        while index + opening.count <= units.count {
            guard Array(units[index..<index + opening.count]) == opening else { index += 1; continue }
            var end = index + opening.count
            while end + closing.count <= units.count, Array(units[end..<end + closing.count]) != closing { end += 1 }
            end = min(end + closing.count, units.count)
            for position in index..<end where units[position] != 0x0A && units[position] != 0x0D {
                units[position] = 0x20
            }
            index = end
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// `text` with the contents of `url(...)` and of quoted strings blanked to spaces, so a
    /// fragment identifier or a string is never read as a colour. Length is unchanged.
    static func maskingStringsAndURLs(_ text: String) -> String {
        var units = Array(text.utf16)
        var index = 0
        var quote: UInt16?
        var urlDepth = 0
        let urlOpen = Array("url(".utf16)
        while index < units.count {
            let unit = units[index]
            if let open = quote {
                if unit == open { quote = nil } else { units[index] = 0x20 }
            } else if urlDepth > 0 {
                if unit == 0x29 { urlDepth -= 1 } else { units[index] = 0x20 }
            } else if unit == 0x22 || unit == 0x27 {
                quote = unit
            } else if index + urlOpen.count <= units.count,
                      Array(units[index..<index + urlOpen.count]).map({ $0 | 0x20 }) == urlOpen {
                urlDepth = 1
                index += urlOpen.count - 1
            }
            index += 1
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// One `property: value` pair and where its value starts.
struct CSSDeclaration: Sendable, Equatable {
    let property: String
    let value: String
    let valueOffset: Int
}

/// Reads declarations from a stylesheet, tracking nesting so a selector is never a declaration.
enum CSSDeclarationReader {

    /// Declarations inside blocks of `units[range]`.
    ///
    /// - Parameter insideBlock: `true` for a bare declaration list such as a `style` attribute.
    static func read(units: [UInt16], range: Range<Int>, insideBlock: Bool) -> [CSSDeclaration] {
        var found: [CSSDeclaration] = []
        var depth = insideBlock ? 1 : 0
        var parentheses = 0
        var quote: UInt16?
        var statementStart = range.lowerBound
        var index = range.lowerBound

        func finishStatement(at end: Int) {
            guard depth > 0, end > statementStart else { return }
            let slice = Array(units[statementStart..<end])
            guard let colon = slice.firstIndex(of: 0x3A) else { return }
            let property = String(decoding: slice[0..<colon], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !property.isEmpty, property.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return }
            found.append(CSSDeclaration(
                property: property,
                value: String(decoding: slice[(colon + 1)...], as: UTF16.self),
                valueOffset: statementStart + colon + 1))
        }

        while index < range.upperBound {
            let unit = units[index]
            if let open = quote {
                if unit == 0x5C { index += 1 } else if unit == open { quote = nil }
            } else if unit == 0x22 || unit == 0x27 {
                quote = unit
            } else if unit == 0x28 {
                parentheses += 1
            } else if unit == 0x29 {
                parentheses = max(parentheses - 1, 0)
            } else if parentheses == 0 {
                if unit == 0x7B {
                    depth += 1
                    statementStart = index + 1
                } else if unit == 0x7D {
                    finishStatement(at: index)
                    depth = max(depth - 1, 0)
                    statementStart = index + 1
                } else if unit == 0x3B {
                    finishStatement(at: index)
                    statementStart = index + 1
                }
            }
            index += 1
        }
        finishStatement(at: range.upperBound)
        return found
    }
}
