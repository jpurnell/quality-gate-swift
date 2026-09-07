import Foundation
#if canImport(os)
import os
#endif

/// Loads the control-mapping reference data bundled with the tool: the curated
/// rule-ID registry, the framework catalogs (`*.catalog.json`), and the
/// rule→control mappings (`*.mapping.json`).
///
/// This is quality-gate's *own* data (the frameworks and the canonical mapping),
/// not the analysed project's — so it ships as module resources, read through
/// `Bundle.module`, never from the project under audit.
public enum ControlMappingResources {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "ControlMapping")

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
        // `decode` reports why it failed; an empty set here means the checker skips.
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
        // A control catalogue that will not load leaves the compliance checker with no
        // controls to map against, and it then passes for want of anything to fail on.
        // Skipping stays the behaviour; being unable to say why does not.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Self.logger.warning(
                "control-mapping could not read resource \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.logger.warning(
                "control-mapping could not decode resource \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
