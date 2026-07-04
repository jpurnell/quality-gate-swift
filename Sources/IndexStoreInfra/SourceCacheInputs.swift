import Foundation
import QualityGateCore

/// Builds the incremental-cache input set for a checker whose result depends on the whole
/// Swift source tree — e.g. the cross-module index checkers, whose analysis spans every module.
public enum SourceCacheInputs {

    /// All `.swift` files under `projectRoot` (honoring `excludePatterns`) plus the package
    /// manifests.
    ///
    /// Deliberately **over-inclusive**: over-including an input only causes extra cache misses
    /// (a re-run), never a stale reuse. This is the conservative side of the cache Safety
    /// Contract — a cross-module checker's result can change if *any* source file changes, so
    /// the fingerprint must cover them all.
    public static func wholeSource(projectRoot: URL, excludePatterns: [String]) -> CacheInputs {
        // Scope to the project's own `Sources`/`Tests` — NOT `projectRoot`, which descends into
        // `.build/checkouts` (thousands of dependency files) and would make the fingerprint
        // ruinously slow. A dependency change is captured via `Package.resolved` below.
        var files: [String] = []
        for subdir in ["Sources", "Tests"] {
            let dir = projectRoot.appendingPathComponent(subdir, isDirectory: true)
            files += SourceWalker.swiftFiles(under: dir, excludePatterns: excludePatterns)
        }
        for manifest in ["Package.swift", "Package.resolved"] {
            files.append(projectRoot.appendingPathComponent(manifest).path)
        }
        return CacheInputs(files: files)
    }
}
