import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// Builds the incremental-cache input set for a checker whose result depends on the whole
/// Swift source tree — e.g. the cross-module index checkers, whose analysis spans every module.
public enum SourceCacheInputs {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "SourceCacheInputs")

    /// All `.swift` files under `projectRoot` (honoring `excludePatterns`) plus the package
    /// manifests.
    ///
    /// Deliberately **over-inclusive**: over-including an input only causes extra cache misses
    /// (a re-run), never a stale reuse. This is the conservative side of the cache Safety
    /// Contract — a cross-module checker's result can change if *any* source file changes, so
    /// the fingerprint must cover them all.
    public static func wholeSource(projectRoot: URL, configuration: Configuration) -> CacheInputs {
        // Walk the project root — the same walk the checkers themselves perform.
        //
        // This used to scope to `Sources`/`Tests` to avoid descending into `.build/checkouts`,
        // which `SourceWalker` has skipped by default for some time; the narrower scope survived
        // the reason for it. The narrowing was an under-specification, and under-specifying is the
        // one direction a cache cannot fail safely in: it serves a stale pass.
        //
        // Concretely, a checker that walks the project root sees `Plugins/` and `scripts/` while
        // this fingerprint did not, so editing the SPM plugin left every cached result valid. Six
        // wait-before-read deadlocks were found in exactly those directories the day this was
        // written.
        var files = SourceWalker.swiftFiles(
            under: projectRoot, excludePatterns: configuration.excludePatterns)
        for manifest in ["Package.swift", "Package.resolved"] {
            files.append(projectRoot.appendingPathComponent(manifest).path)
        }
        // `.gitignore` decides which paths the walk excludes, so it decides the file set a
        // checker sees. A change to it changes results without changing any source file.
        files.append(projectRoot.appendingPathComponent(".gitignore").path)
        // Salt with a digest of the full configuration so ANY config change (thresholds,
        // feature flags, exclusions) invalidates the cached result — a checker's output depends
        // on its config, not just the source. Over-inclusive (whole config) by design.
        return CacheInputs(files: files, salt: configurationSalt(configuration))
    }

    /// Every input `wholeSource` covers, **plus the DocC catalogues**.
    ///
    /// `wholeSource` collects `.swift` files. A documentation checker also reads the `.md` files
    /// inside `.docc` catalogues, and those are not Swift — so fingerprinting a doc checker with
    /// `wholeSource` would let an edited article keep a stale verdict. Under-specifying an input
    /// is the only way a cache can be *wrong* rather than merely slow, so the doc checkers get a
    /// set that covers what they actually read.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - configuration: Project configuration, digested into the salt.
    /// - Returns: Inputs covering Swift sources, manifests, `.gitignore`, and DocC markdown.
    public static func wholeSourceAndDocs(projectRoot: URL, configuration: Configuration) -> CacheInputs {
        let base = wholeSource(projectRoot: projectRoot, configuration: configuration)
        return CacheInputs(files: base.files + docCatalogueFiles(under: projectRoot), salt: base.salt)
    }

    /// Files inside `.docc` catalogues under `projectRoot`.
    ///
    /// Catalogues hold markdown, tutorials and resources; all of them can change what DocC
    /// reports, so all of them are inputs.
    private static func docCatalogueFiles(under projectRoot: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }

        var found: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory == true {
                // Descend into `.docc`; skip the build output that would otherwise dominate.
                if SourceWalker.defaultSkipDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.deletingLastPathComponent().pathComponents.contains(where: { $0.hasSuffix(".docc") }) {
                found.append(url.path)
            }
        }
        return found.sorted()
    }

    /// A stable digest of the entire configuration, for the cache salt.
    static func configurationSalt(_ configuration: Configuration) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return CheckerFingerprint.digest(of: try encoder.encode(configuration))
        } catch {
            logger.warning("Could not encode configuration for cache salt; using empty salt (forces a cache miss): \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }
}
