import Foundation
import IJSSensor
import QualityGateCore

/// One place the CLI resolves layered configuration (Phase 1).
///
/// Wires `ConfigResolver` to the real world: the repo config path from
/// `--config`, the overlay keyed by this checkout's project identity, and the
/// user-global config from `OverlayStore`. Overlay identity always uses the
/// remote-derived slug — overlays are new state with no basename-era legacy
/// to preserve, and they must survive re-clones.
enum LayeredConfig {
    /// The outcome of a layered resolution.
    struct Resolution {
        /// The effective merged configuration.
        let configuration: Configuration
        /// Per-section origins and consulted paths.
        let provenance: ConfigProvenance
        /// The identity slug that keyed the overlay lookup.
        let identity: String
        /// This project's overlay directory (derivable whether or not it
        /// exists on disk yet — forced foreign mode needs somewhere to write).
        let overlayDirectory: URL
        /// Whether an overlay `config.yml` actually exists on disk.
        let hasOverlayConfig: Bool
    }

    /// Resolves configuration for the current working directory.
    ///
    /// - Parameter repoConfigPath: The `--config` value (repo layer).
    /// - Returns: Merged configuration, provenance, and the overlay identity.
    /// - Throws: `QualityGateError.configurationError` when a present layer
    ///   is unreadable or invalid.
    static func resolve(repoConfigPath: String) throws -> Resolution {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let identity = ProjectIdentity.resolve(cwd: cwd, explicitID: nil).id
        let store = OverlayStore.standard()
        let resolver = ConfigResolver(
            repoConfigURL: URL(fileURLWithPath: repoConfigPath),
            overlayConfigURL: store.overlayConfigURL(for: identity),
            userGlobalConfigURL: store.userGlobalConfigURL)
        let (configuration, provenance) = try resolver.resolve()
        return Resolution(
            configuration: configuration,
            provenance: provenance,
            identity: identity,
            overlayDirectory: store.overlayDirectory(for: identity),
            hasOverlayConfig: store.hasOverlay(for: identity))
    }
}
