import Foundation

/// Loads the control-mapping reference data bundled with the tool: the curated
/// rule-ID registry, the framework catalogs (`*.catalog.json`), and the
/// rule→control mappings (`*.mapping.json`).
///
/// This is quality-gate's *own* data (the frameworks and the canonical mapping),
/// not the analysed project's — so it ships as module resources, read through
/// `Bundle.module`, never from the project under audit.
public enum ControlMappingResources {

    /// The wrapper shape of `rule-registry.json`.
    private struct Registry: Codable {
        let ruleIds: [String]
    }

    /// Every rule ID the gate can emit, per the curated registry. Empty if the
    /// resource is absent or unreadable.
    public static func registryRuleIds() -> Set<String> {
        guard let url = Bundle.module.url(forResource: "rule-registry", withExtension: "json") else {
            return []
        }
        // silent: a missing/corrupt registry yields an empty set; the checker then skips rather than crash
        guard let registry: Registry = decode(url) else { return [] }
        return Set(registry.ruleIds)
    }

    /// Every framework catalog (`*.catalog.json`) bundled with the tool.
    public static func catalogs() -> [ControlCatalog] {
        jsonResources(suffix: ".catalog.json").compactMap { decode($0) }
    }

    /// Every rule→control mapping entry across all `*.mapping.json` resources.
    public static func mappings() -> [RuleControlMapping] {
        jsonResources(suffix: ".mapping.json").flatMap { (decode($0) as [RuleControlMapping]?) ?? [] }
    }

    // MARK: - Resource helpers

    /// Bundled `.json` resource URLs whose file name ends with `suffix`
    /// (e.g. `.catalog.json`), sorted for deterministic order.
    private static func jsonResources(suffix: String) -> [URL] {
        let all = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return all.filter { $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Decodes a JSON resource, returning nil on any read/parse failure.
    private static func decode<T: Decodable>(_ url: URL) -> T? {
        // silent: a malformed resource is skipped, not fatal; loaders return empty and the checker skips
        guard let data = try? Data(contentsOf: url) else { return nil }
        // silent: same posture for a decode failure
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
