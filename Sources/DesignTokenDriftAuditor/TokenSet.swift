import Foundation

/// The generated token set, read from `tokens.css` or DesignTokens' `Generated/` CSS.
///
/// Only what the rules compare against is kept: colour values (every appearance, so a literal that
/// matches the dark accent is still a copy), the type scale, radii, the gutter and the column count.
struct TokenSet: Sendable, Equatable {

    /// A named colour value. A role with light and dark values appears once per value.
    struct Colour: Sendable, Equatable {
        let name: String
        let rgb: RGBTriple
        var red: Int { rgb.red }
        var green: Int { rgb.green }
        var blue: Int { rgb.blue }
    }

    /// A named length in CSS pixels.
    struct Size: Sendable, Equatable {
        let name: String
        let px: Double
    }

    var colours: [Colour] = []
    var typeSizes: [Size] = []
    var radii: [Size] = []
    var gutterPx: Double?
    var columns: Int?

    /// Whether nothing checkable was read.
    var isEmpty: Bool {
        colours.isEmpty && typeSizes.isEmpty && radii.isEmpty && gutterPx == nil && columns == nil
    }

    /// The number of distinct tokens read, for the coverage note.
    var count: Int {
        Set(colours.map(\.name)).count + typeSizes.count + radii.count
            + (gutterPx == nil ? 0 : 1) + (columns == nil ? 0 : 1)
    }

    private static let declaration = Support.regex(#"--([A-Za-z0-9_-]+)\s*:\s*([^;}]+)"#)
    private static let length = Support.regex(#"^(-?\d+(?:\.\d+)?)(px)?$"#)

    /// Reads every custom property of interest in `css`; the rest is ignored.
    static func parse(css: String) -> TokenSet {
        var set = TokenSet()
        let text = CSSText.strippingComments(css)
        guard let declaration else { return set }
        let range = NSRange(text.startIndex..., in: text)
        for match in declaration.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            let name = String(text[nameRange])
            let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
            set.record(name: name, value: value)
        }
        return set
    }

    private mutating func record(name: String, value: String) {
        if let rgb = RGBTriple.parse(hex: value), value.hasPrefix("#"), !name.hasSuffix("-rgb") {
            let colour = Colour(name: name, rgb: rgb)
            if !colours.contains(colour) { colours.append(colour) }
        } else if name.hasPrefix("type-"), name.hasSuffix("-size"), let px = Self.pixels(value) {
            let role = String(name.dropFirst("type-".count).dropLast("-size".count))
            if !typeSizes.contains(where: { $0.name == role }) { typeSizes.append(Size(name: role, px: px)) }
        } else if name.hasPrefix("radius-"), let px = Self.pixels(value) {
            let role = String(name.dropFirst("radius-".count))
            if !radii.contains(where: { $0.name == role }) { radii.append(Size(name: role, px: px)) }
        } else if name == "gutter", let px = Self.pixels(value) {
            gutterPx = px
        } else if name == "columns", let count = Int(value) {
            columns = count
        }
    }

    /// A plain length: `16px` or a bare number. Functions such as `clamp()` are not plain.
    private static func pixels(_ value: String) -> Double? {
        guard let length else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = length.firstMatch(in: value, range: range),
              let numberRange = Range(match.range(at: 1), in: value) else { return nil }
        return Double(value[numberRange])
    }

    /// The colour role nearest `rgb`, and how far.
    func nearestColour(red: Int, green: Int, blue: Int) -> (colour: Colour, distance: Double)? {
        let target = RGBTriple(red: red, green: green, blue: blue)
        var best: (colour: Colour, distance: Double)?
        for colour in colours {
            let distance = colour.rgb.distance(to: target)
            if best == nil || distance < (best?.distance ?? .infinity) { best = (colour, distance) }
        }
        return best
    }

    /// The type role nearest `px`; a tie goes to the smaller.
    func nearestTypeRole(px: Double) -> Size? { Self.nearest(typeSizes, to: px) }

    /// The radius role nearest `px`; a tie goes to the smaller.
    func nearestRadius(px: Double) -> Size? { Self.nearest(radii, to: px) }

    /// The colour name whose value equals `rgb` exactly, first in file order.
    func colourName(equalTo rgb: RGBTriple) -> String? { colours.first { $0.rgb == rgb }?.name }

    /// The type role whose size equals `px`.
    func typeRole(equalTo px: Double) -> Size? { typeSizes.first { abs($0.px - px) < 0.0001 } }

    private static func nearest(_ sizes: [Size], to px: Double) -> Size? {
        var best: Size?
        for size in sizes {
            guard let current = best else { best = size; continue }
            let distance = abs(size.px - px)
            let currentDistance = abs(current.px - px)
            if distance < currentDistance || (abs(distance - currentDistance) < 0.0001 && size.px < current.px) {
                best = size
            }
        }
        return best
    }
}
