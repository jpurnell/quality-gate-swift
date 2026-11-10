import Foundation
import QualityGateCore

/// The CSS and HTML rules of `design-token-drift`.
///
/// A small reader, not a regular expression over the file: comments are blanked, `{}` nesting
/// is tracked so `#abc { ... }` is a selector and not a colour, and `url()` and strings are
/// masked. HTML contributes `<style>` blocks, `style` attributes and a few colour attributes;
/// `<script>` and comments are ignored.
enum CSSDrift {

    /// Findings in one CSS or HTML file, in source order.
    ///
    /// - Parameter colourRules: `false` for a declared palette file: colour findings are dropped,
    ///   font-size and column findings still apply.
    static func analyze(
        text: String, fileName: String, isHTML: Bool, tokens: TokenSet, colourRules: Bool = true
    ) -> [Diagnostic] {
        let prepared = CSSText.strippingComments(isHTML ? CSSText.blanking(text, open: "<!--", close: "-->") : text)
        let source = CSSSource(isHTML ? maskingScripts(prepared) : prepared)
        var findings: [Finding] = []
        for region in regions(of: source, isHTML: isHTML) {
            switch region.kind {
            case .stylesheet, .declarationList:
                let declarations = CSSDeclarationReader.read(
                    units: source.units, range: region.range, insideBlock: region.kind == .declarationList)
                for declaration in declarations { findings += check(declaration, tokens: tokens) }
            case .colourAttribute:
                let value = String(decoding: source.units[region.range], as: UTF16.self)
                findings += colourFindings(
                    in: CSSDeclaration(property: "color", value: value, valueOffset: region.range.lowerBound),
                    tokens: tokens)
            }
        }
        let kept = findings.filter { colourRules || !$0.isColour }
        return kept.sorted { $0.offset < $1.offset }.map { finding in
            let location = source.location(of: finding.offset)
            return Diagnostic(
                severity: finding.severity, message: finding.message, filePath: fileName,
                lineNumber: location.line, columnNumber: location.column,
                ruleId: finding.rule, suggestedFix: finding.fix)
        }
    }

    /// Whether the file contains at least one colour literal.
    static func definesColour(text: String, isHTML: Bool) -> Bool {
        analyze(text: text, fileName: "", isHTML: isHTML, tokens: TokenSet())
            .contains { $0.ruleId == "design-token.css-colour" || $0.ruleId == "design-token.css-token-copy" }
    }

    // MARK: - Findings

    private struct Finding {
        let offset: Int
        let rule: String
        let severity: Diagnostic.Severity
        let message: String
        let fix: String
        var isColour = false
    }

    private static func check(_ declaration: CSSDeclaration, tokens: TokenSet) -> [Finding] {
        var findings = colourFindings(in: declaration, tokens: tokens)
        switch declaration.property {
        case "font-size":
            findings += fontSizeFindings(declaration, tokens: tokens)
        case "grid-template-columns", "column-width", "column-gap", "grid-column-gap", "gap", "grid-gap":
            findings += columnFindings(declaration, tokens: tokens)
        default:
            break
        }
        return findings
    }

    // MARK: Colour

    private static let hexLengths: Set<Int> = [4, 5, 7, 9]
    private static let hexLiteral = Support.regex("#[0-9A-Fa-f]+(?![0-9A-Za-z_-])")
    private static let colourFunction = Support.regex(#"\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\("#)

    private static func colourFindings(in declaration: CSSDeclaration, tokens: TokenSet) -> [Finding] {
        let masked = CSSText.maskingStringsAndURLs(declaration.value)
        let nsMasked = masked as NSString
        let whole = NSRange(location: 0, length: nsMasked.length)
        var findings: [Finding] = []

        for match in hexLiteral?.matches(in: masked, range: whole) ?? [] {
            let literal = nsMasked.substring(with: match.range)
            guard Self.hexLengths.contains(literal.count),
                  let rgb = RGBTriple.parse(hex: literal) else { continue }
            findings.append(colourFinding(
                offset: declaration.valueOffset + match.range.location, spelling: literal, rgb: rgb,
                functional: false, tokens: tokens))
        }
        for match in colourFunction?.matches(in: masked, range: whole) ?? [] {
            guard let close = closingParenthesis(in: nsMasked, from: match.range.location + match.range.length) else { continue }
            let literal = nsMasked.substring(with: NSRange(location: match.range.location, length: close - match.range.location + 1))
            guard !literal.contains("var(") else { continue }
            findings.append(colourFinding(
                offset: declaration.valueOffset + match.range.location, spelling: literal,
                rgb: rgbFunctionValue(literal), functional: true, tokens: tokens))
        }
        return findings
    }

    private static func colourFinding(
        offset: Int, spelling: String, rgb: RGBTriple?, functional: Bool, tokens: TokenSet
    ) -> Finding {
        if let rgb, let name = tokens.colourName(equalTo: rgb) {
            let use = functional ? "rgb(var(--\(name)-rgb) / <alpha>)" : "var(--\(name))"
            return Finding(
                offset: offset, rule: "design-token.css-token-copy", severity: .warning,
                message: "Colour \(spelling) is a copy of the token `--\(name)`; it will drift when the tokens are regenerated.",
                fix: "Use `\(use)`.", isColour: true)
        }
        var fix = "Use a colour token (`var(--accent)`, `var(--label)`, ...) from the generated token file."
        if let rgb, let nearest = tokens.nearestColour(red: rgb.red, green: rgb.green, blue: rgb.blue) {
            fix = "Use `var(--\(nearest.colour.name))` (nearest, \(nearest.colour.rgb.hex), distance \(Support.whole(nearest.distance)))."
        }
        return Finding(
            offset: offset, rule: "design-token.css-colour", severity: .error,
            message: "Colour literal \(spelling) is not in the design token set.", fix: fix, isColour: true)
    }

    private static func closingParenthesis(in text: NSString, from start: Int) -> Int? {
        var depth = 1
        var index = start
        while index < text.length {
            let unit = text.character(at: index)
            if unit == 0x28 { depth += 1 }
            if unit == 0x29 {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// `rgb(231, 117, 0)` and `rgb(231 117 0 / 50%)` read as a colour; anything else is `nil`.
    private static func rgbFunctionValue(_ literal: String) -> RGBTriple? {
        guard literal.lowercased().hasPrefix("rgb"),
              let open = literal.firstIndex(of: "("), let close = literal.lastIndex(of: ")") else { return nil }
        let body = literal[literal.index(after: open)..<close]
        let numbers = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0) }
        guard numbers.count >= 3, numbers[0...2].allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }
        return RGBTriple(red: Support.whole(numbers[0]), green: Support.whole(numbers[1]), blue: Support.whole(numbers[2]))
    }

    // MARK: Font size

    private static let dimension = Support.regex(#"^(\d*\.?\d+)(px|pt|rem|em)$"#)

    private static func pixels(_ token: String) -> Double? {
        guard let dimension else { return nil }
        let range = NSRange(token.startIndex..., in: token)
        guard let match = dimension.firstMatch(in: token, range: range),
              let numberRange = Range(match.range(at: 1), in: token),
              let unitRange = Range(match.range(at: 2), in: token),
              let number = Double(token[numberRange]) else { return nil }
        switch token[unitRange] {
        case "px": return number
        case "pt": return number * 4 / 3
        default: return number * 16
        }
    }

    private static func cleaned(_ value: String) -> String {
        value.replacingOccurrences(of: "!important", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fontSizeFindings(_ declaration: CSSDeclaration, tokens: TokenSet) -> [Finding] {
        let value = cleaned(declaration.value)
        guard !value.isEmpty, !value.contains("var("), !value.hasSuffix("%"),
              !value.allSatisfy({ $0.isLetter || $0 == "-" }) else { return [] }
        let offset = declaration.valueOffset + leadingBlanks(declaration.value)
        // `em` is relative to the parent, so it never equals a token; only `1em` (inherit) is allowed.
        if value.lowercased() == "1em" { return [] }
        let isRelative = value.lowercased().hasSuffix("em") && !value.lowercased().hasSuffix("rem")
        guard !isRelative, let px = pixels(value) else {
            return [Finding(
                offset: offset, rule: "design-token.css-font-size", severity: .error,
                message: "Font size `\(value)` is not in the design token set.",
                fix: "Use a type token such as `var(--type-body-size)`.")]
        }
        if let role = tokens.typeRole(equalTo: px) {
            return [Finding(
                offset: offset, rule: "design-token.css-token-copy", severity: .warning,
                message: "Font size \(value) is a copy of the token `--type-\(role.name)-size`; it will drift when the tokens are regenerated.",
                fix: "Use `var(--type-\(role.name)-size)`.")]
        }
        var fix = "Use a type token such as `var(--type-body-size)`."
        if let nearest = tokens.nearestTypeRole(px: px) {
            fix = "Use `var(--type-\(nearest.name)-size)` (nearest, \(Support.whole(nearest.px))px)."
        }
        return [Finding(
            offset: offset, rule: "design-token.css-font-size", severity: .error,
            message: "Font size \(value) is not in the design token set.", fix: fix)]
    }

    private static func leadingBlanks(_ value: String) -> Int {
        value.utf16.prefix { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }.count
    }

    // MARK: Columns

    private static let repeatCount = Support.regex(#"repeat\(\s*(\d+)\s*,"#)
    private static let fixedLength = Support.regex(#"(?<![\w.-])\d*\.?\d+(?:px|rem|em|%|ch|vw|vh|pt)\b"#)

    private static func columnFindings(_ declaration: CSSDeclaration, tokens: TokenSet) -> [Finding] {
        let value = cleaned(declaration.value)
        guard !value.isEmpty else { return [] }
        let offset = declaration.valueOffset + leadingBlanks(declaration.value)
        let whole = NSRange(value.startIndex..., in: value)

        switch declaration.property {
        case "grid-template-columns":
            let fixed = fixedLength?.firstMatch(in: value, range: whole) != nil
            var count: Int?
            if let match = repeatCount?.firstMatch(in: value, range: whole), let range = Range(match.range(at: 1), in: value) {
                count = Int(value[range])
            }
            if fixed || (count != nil && count != tokens.columns) {
                return [Finding(
                    offset: offset, rule: "design-token.css-column", severity: .error,
                    message: "Column definition `\(value)` is not built from the grid tokens (12 columns, `--gutter`).",
                    fix: "Use `repeat(var(--columns), 1fr)` and span with `grid-column`.")]
            }
            if let count, count == tokens.columns {
                return [Finding(
                    offset: offset, rule: "design-token.css-token-copy", severity: .warning,
                    message: "Column count \(count) is a copy of the token `--columns`; it will drift when the tokens are regenerated.",
                    fix: "Use `repeat(var(--columns), 1fr)`.")]
            }
            return []
        case "column-width":
            guard fixedLength?.firstMatch(in: value, range: whole) != nil else { return [] }
            return [Finding(
                offset: offset, rule: "design-token.css-column", severity: .error,
                message: "Column width `\(value)` is not in the design token set.",
                fix: "Size columns by spanning the 12-column grid, not by a fixed width.")]
        default:
            // column-gap, grid-column-gap, gap, grid-gap
            let lengths = value.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            let literals = lengths.compactMap { pixels($0) }.filter { $0 != 0 }
            guard !literals.isEmpty else { return [] }
            if let gutter = tokens.gutterPx, literals.allSatisfy({ abs($0 - gutter) < 0.0001 }) {
                return [Finding(
                    offset: offset, rule: "design-token.css-token-copy", severity: .warning,
                    message: "Gap \(value) is a copy of the token `--gutter`; it will drift when the tokens are regenerated.",
                    fix: "Use `var(--gutter)`.")]
            }
            return [Finding(
                offset: offset, rule: "design-token.css-column", severity: .error,
                message: "Gap `\(value)` is not the grid gutter.", fix: "Use `var(--gutter)`.")]
        }
    }

    // MARK: - HTML regions

    private struct Region {
        enum Kind { case stylesheet, declarationList, colourAttribute }
        let kind: Kind
        let range: Range<Int>
    }

    private static func regions(of source: CSSSource, isHTML: Bool) -> [Region] {
        guard isHTML else { return [Region(kind: .stylesheet, range: 0..<source.units.count)] }
        let text = source.text
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [Region] = []

        for match in styleBlock?.matches(in: text, range: whole) ?? [] where match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            found.append(Region(kind: .stylesheet, range: range.location..<range.location + range.length))
        }
        for match in styleAttribute?.matches(in: text, range: whole) ?? [] {
            for group in 2...3 where match.range(at: group).location != NSNotFound {
                let range = match.range(at: group)
                found.append(Region(kind: .declarationList, range: range.location..<range.location + range.length))
            }
        }
        for match in colourAttribute?.matches(in: text, range: whole) ?? [] {
            for group in 2...3 where match.range(at: group).location != NSNotFound {
                let range = match.range(at: group)
                found.append(Region(kind: .colourAttribute, range: range.location..<range.location + range.length))
            }
        }
        return found
    }

    private static let styleBlock = Support.regex(#"<style\b[^>]*>(.*?)</style>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
    private static let styleAttribute = Support.regex(#"(?<![\w-])(style)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive])
    private static let colourAttribute = Support.regex(#"(?<![\w-])(fill|stroke|stop-color|flood-color|bgcolor|color)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive])

    /// Blanks `<script>...</script>` so code in it is never read as style.
    private static func maskingScripts(_ text: String) -> String {
        guard let scripts = Support.regex(#"<script\b[^>]*>.*?</script>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return text }
        var units = Array(text.utf16)
        for match in scripts.matches(in: text, range: NSRange(location: 0, length: units.count)) {
            for index in match.range.location..<match.range.location + match.range.length
            where units[index] != 0x0A && units[index] != 0x0D {
                units[index] = 0x20
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
