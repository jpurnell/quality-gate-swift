import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// The Swift-side rules of `design-token-drift`: colour literals, fixed fonts and hard-coded radii.
///
/// Syntactic by design. There is no type resolution, so `.init(red:green:blue:)` is recognised by
/// its labels and a `0xRRGGBB` literal only by the label or name it is bound to. A flagged
/// literal is a colour literal; a colour built from a constant defined elsewhere is not seen.
enum SwiftDrift {

    /// Findings in one Swift source, in source order.
    ///
    /// - Parameter colourRules: `false` for a declared app-palette file, which is exempt from the
    ///   colour-literal rules only; fonts and radii still apply in it.
    static func analyze(
        source: String, fileName: String, tokens: TokenSet, colourRules: Bool = true
    ) -> [Diagnostic] {
        let tree = Parser.parse(source: source)
        let visitor = DriftVisitor(fileName: fileName, tokens: tokens, tree: tree)
        visitor.walk(tree)
        let colourIDs: Set<String> = ["design-token.hex-colour", "design-token.rgb-initialiser"]
        return visitor.diagnostics.filter { colourRules || !colourIDs.contains($0.ruleId ?? "") }.sorted {
            ($0.lineNumber ?? 0, $0.columnNumber ?? 0) < ($1.lineNumber ?? 0, $1.columnNumber ?? 0)
        }
    }

    /// The app-palette marker of DesignTokens 0.8.0, read syntactically.
    ///
    /// Contract: `2026-11-10_AppPaletteAdoption.md` §2.1. A file carries the marker when a struct,
    /// enum, class, actor or extension lists `AppPaletteSource` (or `DesignTokens.AppPaletteSource`)
    /// in its inheritance clause. It is *valid* when exactly one declaration does and exactly one
    /// `AppPalette(id: "<literal>"` call exists. A comment is never a marker.
    static func paletteMarker(source: String) -> PaletteMarker {
        let tree = Parser.parse(source: source)
        let finder = MarkerFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return PaletteMarker(conformers: finder.conformers, paletteCalls: finder.calls, ids: finder.ids)
    }

    /// Whether `source` defines at least one colour, by the same detectors the rules use.
    ///
    /// This is what makes a declared palette file a palette: a listed file that defines no colour
    /// exempts nothing and is reported as empty.
    static func definesColour(source: String) -> Bool {
        let found = analyze(source: source, fileName: "", tokens: TokenSet())
        return found.contains { $0.ruleId == "design-token.hex-colour" || $0.ruleId == "design-token.rgb-initialiser" }
    }
}

// MARK: - Visitor

private final class DriftVisitor: SyntaxVisitor {
    private(set) var diagnostics: [Diagnostic] = []
    private let fileName: String
    private let tokens: TokenSet
    private let converter: SourceLocationConverter
    private var reported: Set<Int> = []

    private static let hexLabels: Set<String> = ["hex", "hexString", "hexValue", "hexCode", "rgb", "rgba", "argb"]
    private static let colourWords = ["color", "colour", "hex", "tint", "accent", "fill", "stroke"]
    private static let colourTypes: Set<String> = ["Color", "UIColor", "NSColor", "CGColor", "CIColor"]
    private static let rgbLabels: Set<String> = ["red", "calibratedRed", "srgbRed", "deviceRed"]
    private static let greyLabels: Set<String> = ["white", "calibratedWhite", "deviceWhite", "genericGamma22White", "gray"]
    private static let hueLabels: Set<String> = ["hue", "calibratedHue", "deviceHue"]
    private static let componentLabels: Set<String> = [
        "red", "green", "blue", "calibratedRed", "calibratedGreen", "calibratedBlue",
        "srgbRed", "srgbGreen", "srgbBlue", "deviceRed", "deviceGreen", "deviceBlue",
        "white", "calibratedWhite", "deviceWhite", "genericGamma22White", "gray",
        "hue", "saturation", "brightness", "calibratedHue", "calibratedSaturation",
        "calibratedBrightness", "deviceHue", "deviceSaturation", "deviceBrightness",
    ]
    private static let systemFontNames: Set<String> = [
        "systemFont", "boldSystemFont", "italicSystemFont", "monospacedSystemFont", "monospacedDigitSystemFont",
    ]

    init(fileName: String, tokens: TokenSet, tree: SourceFileSyntax) {
        self.fileName = fileName
        self.tokens = tokens
        self.converter = SourceLocationConverter(fileName: fileName, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Reporting

    private func add(
        _ node: some SyntaxProtocol, rule: String, message: String, fix: String?, dedupe: Bool = true
    ) {
        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        if dedupe, !reported.insert(offset).inserted { return }
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        diagnostics.append(Diagnostic(
            severity: .error, message: message, filePath: fileName,
            lineNumber: location.line, columnNumber: location.column, ruleId: rule, suggestedFix: fix))
    }

    private func reportColour(_ node: some SyntaxProtocol, rgb: RGBTriple?, spelling: String) {
        add(node, rule: "design-token.hex-colour",
            message: "Hard-coded colour \(spelling) written outside the design tokens.",
            fix: colourFix(rgb))
    }

    private func colourFix(_ rgb: RGBTriple?) -> String {
        guard let rgb, let nearest = tokens.nearestColour(red: rgb.red, green: rgb.green, blue: rgb.blue) else {
            return "Use a colour role from DesignTokens, or declare this file as an app palette in designTokens.exemptPaletteFiles."
        }
        let value = nearest.colour.rgb.hex
        if nearest.distance < 0.5 {
            return "Use the colour role `\(nearest.colour.name)` (equals \(value))."
        }
        return "Use the colour role `\(nearest.colour.name)` (nearest, \(value), distance \(Support.whole(nearest.distance)))."
    }

    // MARK: Literals

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard let text = Self.plainText(of: node) else { return .visitChildren }
        if text.hasPrefix("#"), let rgb = RGBTriple.parse(hex: text, allowShort: false) {
            reportColour(node, rgb: rgb, spelling: text)
        }
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard let identifier = node.pattern.as(IdentifierPatternSyntax.self),
              Self.isColourName(identifier.identifier.text),
              let integer = node.initializer?.value.as(IntegerLiteralExprSyntax.self),
              let rgb = RGBTriple.parse(integerLiteral: integer.literal.text, requireFullWidth: true)
        else { return .visitChildren }
        reportColour(integer, rgb: rgb, spelling: integer.literal.text)
        return .visitChildren
    }

    // MARK: Calls

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = Callee(node.calledExpression)
        checkHexArguments(node)
        checkColourInitialiser(node, callee: callee)
        checkFont(node, callee: callee)
        checkRadius(node, callee: callee)
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count == 3,
              elements[1].is(AssignmentExprSyntax.self),
              let member = elements[0].as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "cornerRadius",
              let radius = Self.number(elements[2]) else { return .visitChildren }
        reportRadius(node, radius: radius)
        return .visitChildren
    }

    private func checkHexArguments(_ node: FunctionCallExprSyntax) {
        for argument in node.arguments {
            guard let label = argument.label?.text else { continue }
            let value = argument.expression
            if Self.hexLabels.contains(label) {
                if let integer = value.as(IntegerLiteralExprSyntax.self),
                   let rgb = RGBTriple.parse(integerLiteral: integer.literal.text, requireFullWidth: false) {
                    reportColour(integer, rgb: rgb, spelling: integer.literal.text)
                } else if let string = value.as(StringLiteralExprSyntax.self),
                          let text = Self.plainText(of: string),
                          let rgb = RGBTriple.parse(hex: text) {
                    reportColour(string, rgb: rgb, spelling: text.hasPrefix("#") ? text : "#\(text)")
                }
            } else if Self.isColourName(label),
                      let integer = value.as(IntegerLiteralExprSyntax.self),
                      let rgb = RGBTriple.parse(integerLiteral: integer.literal.text, requireFullWidth: true) {
                reportColour(integer, rgb: rgb, spelling: integer.literal.text)
            }
        }
    }

    private func checkColourInitialiser(_ node: FunctionCallExprSyntax, callee: Callee) {
        let isColourType = callee.base == nil && callee.isInit
            ? true
            : Self.colourTypes.contains(callee.typeName ?? "")
        guard isColourType else { return }
        let arguments = Array(node.arguments)
        let labels = Set(arguments.compactMap { $0.label?.text })
        let isRGB = !labels.isDisjoint(with: Self.rgbLabels)
        let isGrey = !labels.isDisjoint(with: Self.greyLabels)
        let isHue = !labels.isDisjoint(with: Self.hueLabels)
        guard isRGB || isGrey || isHue else { return }
        // A hard-coded colour has a literal component. All-computed components are colour maths.
        let components = arguments.filter { Self.componentLabels.contains($0.label?.text ?? "") }
        guard components.contains(where: { Self.number($0.expression) != nil }) else { return }

        var rgb: RGBTriple?
        if isRGB {
            let values = components.compactMap { Self.number($0.expression) }
            if values.count == 3 {
                rgb = RGBTriple.fromUnit(red: values[0], green: values[1], blue: values[2])
            }
        } else if isGrey, components.count == 1, let white = Self.number(components[0].expression) {
            rgb = RGBTriple.fromUnit(red: white, green: white, blue: white)
        }
        let typeName = callee.typeName ?? "Color"
        add(node, rule: "design-token.rgb-initialiser",
            message: "Hard-coded colour from \(typeName)'s component initialiser, written outside the design tokens.",
            fix: colourFix(rgb))
    }

    private func checkFont(_ node: FunctionCallExprSyntax, callee: Callee) {
        let arguments = Array(node.arguments)
        let labels = arguments.map { $0.label?.text }
        var sizeExpression: ExprSyntax?
        var isFont = false

        if callee.name == "system", callee.isFontBase, labels.first == "size" {
            isFont = true
            sizeExpression = arguments.first?.expression
        } else if callee.name == "custom", callee.isFontBase,
                  let first = arguments.first, first.label == nil,
                  first.expression.is(StringLiteralExprSyntax.self),
                  let sized = arguments.first(where: { $0.label?.text == "size" || $0.label?.text == "fixedSize" }) {
            isFont = true
            sizeExpression = sized.expression
        } else if Self.systemFontNames.contains(callee.name ?? ""),
                  ["UIFont", "NSFont"].contains(callee.base ?? ""), labels.first == "ofSize" {
            isFont = true
            sizeExpression = arguments.first?.expression
        } else if callee.base == nil, ["UIFont", "NSFont"].contains(callee.name ?? ""),
                  labels == ["name", "size"] {
            isFont = true
            sizeExpression = arguments.last?.expression
        }
        guard isFont else { return }

        var fix = "Use a type role from the design tokens' type scale (Dynamic Type text styles in the UI register)."
        if let sizeExpression, let px = Self.number(sizeExpression), let role = tokens.nearestTypeRole(px: px) {
            let roleSize = formatted(role.px)
            fix = abs(role.px - px) < 0.0001
                ? "Use the type role `\(role.name)` (\(roleSize)px, the same size)."
                : "Use the type role `\(role.name)` (nearest, \(roleSize)px)."
        }
        add(node, rule: "design-token.font",
            message: "Fixed-size or custom font written outside the design tokens.", fix: fix)
    }

    private func checkRadius(_ node: FunctionCallExprSyntax, callee: Callee) {
        for argument in node.arguments where argument.label?.text == "cornerRadius" {
            if let radius = Self.number(argument.expression) {
                reportRadius(argument.expression, radius: radius)
            }
        }
        if callee.name == "cornerRadius", callee.base != nil || callee.isMember,
           let first = node.arguments.first, first.label == nil, let radius = Self.number(first.expression) {
            reportRadius(first.expression, radius: radius)
        }
    }

    private func reportRadius(_ node: some SyntaxProtocol, radius: Double) {
        var fix = "Use a radius from the design tokens: `container` (0) or `control` (4pt)."
        if let role = tokens.nearestRadius(px: radius) {
            fix = abs(role.px - radius) < 0.0001
                ? "Use the radius token `\(role.name)` (\(formatted(role.px))pt, the same value)."
                : "Use the radius token `\(role.name)` (nearest, \(formatted(role.px))pt)."
        }
        add(node, rule: "design-token.corner-radius",
            message: "Hard-coded corner radius \(formatted(radius)) written outside the design tokens.", fix: fix)
    }

    // MARK: Helpers

    private func formatted(_ value: Double) -> String {
        if let whole = Int(exactly: value) { return String(whole) }
        return String(value)
    }

    private static func isColourName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return colourWords.contains { lowered.contains($0) }
    }

    /// The text of a string literal with no interpolation, or `nil`.
    private static func plainText(of node: StringLiteralExprSyntax) -> String? {
        let pieces = node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }
        return pieces.count == node.segments.count ? pieces.joined() : nil
    }

    /// The value of an integer or float literal, with an optional leading sign.
    private static func number(_ expression: ExprSyntax) -> Double? {
        if let integer = expression.as(IntegerLiteralExprSyntax.self) {
            return Double(integer.literal.text.replacingOccurrences(of: "_", with: ""))
        }
        if let float = expression.as(FloatLiteralExprSyntax.self) {
            return Double(float.literal.text.replacingOccurrences(of: "_", with: ""))
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self),
           prefix.operator.text == "-", let inner = number(prefix.expression) {
            return -inner
        }
        return nil
    }
}

/// What a call is calling, read from its callee expression alone.
private struct Callee {
    /// The member or function name: `system` in `Font.system(...)`, `Color` in `Color(...)`.
    let name: String?
    /// The text before the member: `Font` in `Font.system(...)`; `nil` for a bare name or an implicit member.
    let base: String?
    /// Whether the callee is an implicit member such as `.system(...)` or `.init(...)`.
    let isMember: Bool

    init(_ expression: ExprSyntax) {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            name = reference.baseName.text
            base = nil
            isMember = false
        } else if let member = expression.as(MemberAccessExprSyntax.self) {
            name = member.declName.baseName.text
            base = member.base?.trimmedDescription
            isMember = member.base == nil
        } else {
            name = nil
            base = nil
            isMember = false
        }
    }

    var isInit: Bool { name == "init" }

    /// The type a constructor call builds: `Color` in `Color(...)` and in `Color.init(...)`.
    var typeName: String? {
        if base == nil, !isMember { return name }
        if isInit { return base }
        return nil
    }

    /// Whether the call is on SwiftUI's `Font`, spelled out or implicit.
    var isFontBase: Bool { base == nil || base == "Font" || base == "SwiftUI.Font" }
}

/// What the app-palette marker looks like in one file.
struct PaletteMarker: Sendable, Equatable {
    /// Names of declarations whose inheritance clause lists `AppPaletteSource`.
    let conformers: [String]
    /// How many `AppPalette(` calls the file makes.
    let paletteCalls: Int
    /// The string-literal `id:` of each such call that has one.
    let ids: [String]

    /// Whether the file carries the marker at all.
    var present: Bool { !conformers.isEmpty }
    /// The contract's required shape: one conformer, one call, one literal id.
    var isValid: Bool { conformers.count == 1 && paletteCalls == 1 && ids.count == 1 }
}

private final class MarkerFinder: SyntaxVisitor {
    private(set) var conformers: [String] = []
    private(set) var calls = 0
    private(set) var ids: [String] = []

    private func note(_ name: String, _ clause: InheritanceClauseSyntax?) {
        guard let clause else { return }
        let names = clause.inheritedTypes.map { $0.type.trimmedDescription }
        if names.contains("AppPaletteSource") || names.contains("DesignTokens.AppPaletteSource") {
            conformers.append(name)
        }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        note(node.name.text, node.inheritanceClause); return .visitChildren
    }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        note(node.name.text, node.inheritanceClause); return .visitChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        note(node.name.text, node.inheritanceClause); return .visitChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        note(node.name.text, node.inheritanceClause); return .visitChildren
    }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        note(node.extendedType.trimmedDescription, node.inheritanceClause); return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression.trimmedDescription
        guard callee == "AppPalette" || callee == "DesignTokens.AppPalette" else { return .visitChildren }
        calls += 1
        if let first = node.arguments.first, first.label?.text == "id",
           let literal = first.expression.as(StringLiteralExprSyntax.self) {
            let pieces = literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }
            if pieces.count == literal.segments.count { ids.append(pieces.joined()) }
        }
        return .visitChildren
    }
}
