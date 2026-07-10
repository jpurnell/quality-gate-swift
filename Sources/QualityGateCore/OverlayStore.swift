import Foundation

/// The on-disk layout of contributor-side state under `~/.quality-gate/`.
///
/// One type owns every overlay path so ``ConfigResolver``, the CLI, and
/// `RunEnvironment` can never disagree about where overlay state lives:
///
/// ```
/// ~/.quality-gate/
///   config.yml                  # user-global defaults
///   overlays/<identity>/
///     config.yml                # per-project overlay config
///     artifacts/                # redirected artifacts (foreign mode)
///     cache/                    # redirected result cache
/// ```
///
/// Identities are the Phase 0.4 `org__repo` slugs, so an overlay survives
/// re-clones of the same upstream.
public struct OverlayStore: Sendable {
    /// Environment variable that relocates the store root (used by tests and
    /// sandboxed runs); falls back to `$HOME/.quality-gate`.
    public static let homeOverrideVariable = "QUALITY_GATE_HOME"

    /// Directory that holds `config.yml` and `overlays/`.
    public let root: URL

    /// Creates a store rooted at an explicit directory.
    ///
    /// - Parameter root: The store root; nothing is created on disk.
    public init(root: URL) {
        self.root = root
    }

    /// The store for this user: `$QUALITY_GATE_HOME` if set, else
    /// `$HOME/.quality-gate`.
    ///
    /// - Parameter environment: Process environment (injectable for tests).
    /// - Returns: The resolved store; nothing is created on disk.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OverlayStore {
        if let override = environment[homeOverrideVariable], !override.isEmpty {
            return OverlayStore(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return OverlayStore(root: URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".quality-gate", isDirectory: true))
    }

    /// Location of the user-global `config.yml`.
    public var userGlobalConfigURL: URL {
        root.appendingPathComponent("config.yml")
    }

    /// Directory holding one project's overlay state.
    ///
    /// - Parameter identity: The project identity slug; sanitized so a
    ///   malformed or hostile value cannot escape `overlays/`.
    public func overlayDirectory(for identity: String) -> URL {
        root.appendingPathComponent("overlays", isDirectory: true)
            .appendingPathComponent(Self.sanitized(identity), isDirectory: true)
    }

    /// Location of one project's overlay `config.yml`.
    ///
    /// - Parameter identity: The project identity slug.
    public func overlayConfigURL(for identity: String) -> URL {
        overlayDirectory(for: identity).appendingPathComponent("config.yml")
    }

    /// Directory foreign-mode artifact writes are redirected to.
    ///
    /// - Parameter identity: The project identity slug.
    public func artifactsDirectory(for identity: String) -> URL {
        overlayDirectory(for: identity).appendingPathComponent("artifacts", isDirectory: true)
    }

    /// Directory the result cache is redirected to in foreign mode.
    ///
    /// - Parameter identity: The project identity slug.
    public func cacheDirectory(for identity: String) -> URL {
        overlayDirectory(for: identity).appendingPathComponent("cache", isDirectory: true)
    }

    /// Whether an overlay config exists on disk for this identity.
    ///
    /// - Parameter identity: The project identity slug.
    /// - Returns: true when `overlays/<identity>/config.yml` is present.
    public func hasOverlay(for identity: String) -> Bool {
        FileManager.default.fileExists(atPath: overlayConfigURL(for: identity).path)
    }

    /// Collapses an identity slug into a single safe path component.
    ///
    /// Path separators and traversal dots become underscores, so every
    /// overlay stays strictly inside `overlays/` no matter what the
    /// identity resolution produced.
    private static func sanitized(_ identity: String) -> String {
        let component = identity
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let trimmed = component.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "_unknown" : trimmed
    }
}
