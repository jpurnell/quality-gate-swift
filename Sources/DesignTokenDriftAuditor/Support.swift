import Foundation
import QualityGateLogging

/// Small shared helpers.
enum Support {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "DesignTokenDriftAuditor")

    /// Compiles a constant pattern. A failure is logged, never silent; the patterns are literals
    /// and the tests fire every rule that depends on one, so a bad pattern fails them.
    static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            logger.error("design-token-drift pattern failed to compile: \(pattern, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `value` rounded to the nearest whole number; `0` for NaN or a value no `Int` holds.
    static func whole(_ value: Double) -> Int {
        Int(exactly: value.rounded()) ?? 0
    }

    /// Two upper-case hex digits for a 0...255 channel.
    static func hexByte(_ channel: Int) -> String {
        let digits = String(min(max(channel, 0), 255), radix: 16, uppercase: true)
        return digits.count == 1 ? "0" + digits : digits
    }
}
