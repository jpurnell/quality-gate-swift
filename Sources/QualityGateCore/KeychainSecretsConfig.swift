import Foundation
import QualityGateTypes

/// Configuration for the `keychain-secrets` checker.
///
/// The checker flags credentials/tokens written to `UserDefaults` (a plaintext
/// `.plist`, unencrypted at rest and swept into device backups) and points the
/// developer at the Keychain. Defaults favour precision: a string-literal key
/// naming a secret gates at ``Diagnostic/Severity/error``; a match seen only in
/// the stored value's identifier name is softened to `.warning`.
public struct KeychainSecretsConfig: Sendable, Codable, Equatable {

    /// Severity for a high-confidence match — a `UserDefaults` write whose
    /// string-literal `forKey:` names a secret. Default ``Diagnostic/Severity/error``.
    ///
    /// A lower-confidence match (secret noun seen only in the stored value's
    /// identifier, key unremarkable) is reported one step down, never above
    /// `.warning`, so lowering this knob lowers both.
    public var severity: Diagnostic.Severity

    /// Exact keys to exempt — declared false positives (e.g. a boolean flag
    /// whose name merely contains a secret noun). Config-level allow-list;
    /// matched writes are skipped.
    public var allowKeys: [String]

    /// Project-specific secret nouns to add to the built-in vocabulary
    /// (e.g. `"jwt"`, `"otp"`). Case-insensitive; matched like the defaults.
    public var extraPatterns: [String]

    /// Creates a configuration; every knob defaults to the documented value.
    public init(
        severity: Diagnostic.Severity = .error,
        allowKeys: [String] = [],
        extraPatterns: [String] = []
    ) {
        self.severity = severity
        self.allowKeys = allowKeys
        self.extraPatterns = extraPatterns
    }

    private enum CodingKeys: String, CodingKey {
        case severity, allowKeys, extraPatterns
    }

    /// Decodes with defaults for absent keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        severity = try container.decodeIfPresent(Diagnostic.Severity.self, forKey: .severity) ?? .error
        allowKeys = try container.decodeIfPresent([String].self, forKey: .allowKeys) ?? []
        extraPatterns = try container.decodeIfPresent([String].self, forKey: .extraPatterns) ?? []
    }
}
