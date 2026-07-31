import Foundation

/// Configuration for the `privacy-manifest` checker.
///
/// The checker only acts on projects that build an **app bundle** — a pure SPM
/// library has no App Store obligation and is skipped. When it does act, it
/// verifies a `PrivacyInfo.xcprivacy` exists, parses, and (by default) carries
/// the expected top-level keys.
public struct PrivacyManifestConfig: Sendable, Codable, Equatable {

    /// Explicit app-target names. Non-empty forces app-mode, overriding the
    /// heuristic — use it when a project's app-ness can't be detected (or to
    /// disambiguate an app inside a multi-target package).
    public var appTargets: [String]

    /// Whether a present manifest must also carry the expected top-level keys
    /// (`NSPrivacyTracking`, `NSPrivacyTrackingDomains`,
    /// `NSPrivacyCollectedDataTypes`, `NSPrivacyAccessedAPITypes`). Default true;
    /// a missing key is a warning, not an error.
    public var requireTopLevelKeys: Bool

    /// Creates a configuration; every knob defaults to the documented value.
    public init(appTargets: [String] = [], requireTopLevelKeys: Bool = true) {
        self.appTargets = appTargets
        self.requireTopLevelKeys = requireTopLevelKeys
    }

    private enum CodingKeys: String, CodingKey {
        case appTargets, requireTopLevelKeys
    }

    /// Decodes with defaults for absent keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appTargets = try container.decodeIfPresent([String].self, forKey: .appTargets) ?? []
        requireTopLevelKeys = try container.decodeIfPresent(Bool.self, forKey: .requireTopLevelKeys) ?? true
    }
}
