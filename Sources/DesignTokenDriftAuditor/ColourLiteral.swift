import Foundation

/// An sRGB colour read from a literal, 0...255 per channel.
struct RGBTriple: Sendable, Equatable {
    let red: Int
    let green: Int
    let blue: Int

    /// `#RRGGBB`, upper case.
    var hex: String { "#" + Support.hexByte(red) + Support.hexByte(green) + Support.hexByte(blue) }

    /// Euclidean distance in sRGB 0...255.
    func distance(to other: RGBTriple) -> Double {
        let dr = Double(red - other.red)
        let dg = Double(green - other.green)
        let db = Double(blue - other.blue)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Reads `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, with or without the `#`.
    ///
    /// - Parameter allowShort: Whether the three and four digit forms count. Off for a bare string
    ///   literal, where `"#123"` is as likely to be a ticket number as a colour.
    static func parse(hex text: String, allowShort: Bool = true) -> RGBTriple? {
        var digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        switch digits.count {
        case 3, 4:
            guard allowShort else { return nil }
            digits = digits.prefix(3).map { "\($0)\($0)" }.joined()
        case 6:
            break
        case 8:
            digits = String(digits.prefix(6))
        default:
            return nil
        }
        guard let value = Int(digits, radix: 16) else { return nil }
        return RGBTriple(red: (value >> 16) & 0xFF, green: (value >> 8) & 0xFF, blue: value & 0xFF)
    }

    /// The colour in `0xRRGGBB` / `0xRRGGBBAA` integer-literal text, or `nil` for any other length.
    static func parse(integerLiteral text: String, requireFullWidth: Bool) -> RGBTriple? {
        let lowered = text.lowercased().replacingOccurrences(of: "_", with: "")
        guard lowered.hasPrefix("0x") else { return nil }
        let digits = String(lowered.dropFirst(2))
        if requireFullWidth {
            guard digits.count == 6 || digits.count == 8 else { return nil }
        }
        return parse(hex: digits)
    }

    /// Channels from a 0...1 initialiser (`Color(red:green:blue:)`), clamped and rounded.
    static func fromUnit(red: Double, green: Double, blue: Double) -> RGBTriple {
        func channel(_ value: Double) -> Int { Support.whole(min(max(value, 0), 1) * 255) }
        return RGBTriple(red: channel(red), green: channel(green), blue: channel(blue))
    }
}
