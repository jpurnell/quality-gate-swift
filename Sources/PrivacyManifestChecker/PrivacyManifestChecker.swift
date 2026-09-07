import Foundation
#if canImport(os)
import os
#endif
import IndexStoreInfra
import QualityGateCore

/// Verifies that an app bundle ships a well-formed `PrivacyInfo.xcprivacy`.
///
/// Apple rejects an app submission with a missing or malformed privacy
/// manifest, and (post-2024) required-reason APIs must be declared. That
/// feedback otherwise arrives at *submission*, mid-release-crunch. This checker
/// moves it left to commit time.
///
/// **Opt-in by detection.** It does nothing unless it *positively* identifies
/// an app target (an `Info.plist` with app markers, an `.xcodeproj` application
/// product type, or an explicit `appTargets` config entry). A pure SPM library
/// is skipped — flagging a library for a manifest it never needs would train
/// users to disable the checker, so the risk is biased toward under-flagging.
public struct PrivacyManifestChecker: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "PrivacyManifestChecker")

    /// The checker identifier.
    public let id = "privacy-manifest"
    /// The human-readable name.
    public let name = "Privacy Manifest Checker"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "App targets missing or with a malformed `PrivacyInfo.xcprivacy` — opt-in by app detection, so pure SPM libraries are skipped"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.safetySecurity

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// App-detection override and key-strictness.
    let config: PrivacyManifestConfig
    /// Package root to scan; nil means the current working directory.
    let root: String?

    /// The top-level keys a privacy manifest is expected to declare.
    static let requiredKeys = [
        "NSPrivacyTracking",
        "NSPrivacyTrackingDomains",
        "NSPrivacyCollectedDataTypes",
        "NSPrivacyAccessedAPITypes",
    ]

    /// Creates the checker.
    ///
    /// - Parameters:
    ///   - config: App-target override and top-level-key strictness.
    ///   - root: Package root to scan (defaults to the working directory;
    ///     injectable for tests).
    public init(config: PrivacyManifestConfig = PrivacyManifestConfig(), root: String? = nil) {
        self.config = config
        self.root = root
    }

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or out-of-tree path
    /// among its inputs — so the same tree under the same gate binary yields the same verdict.
    /// `gateIdentityHash` folds in the binary's identity and the toolchain, so a rebuild or a
    /// compiler change invalidates every entry.
    ///
    /// `wholeSourceAndDocs` rather than `wholeSource`: it is the wider set, and over-including
    /// an input costs a cache miss while under-including one serves a stale pass.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Inspects the project root for app-ness and a valid privacy manifest.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let scanRoot = root ?? configuration.resolvedProjectRoot.path
        let outcome = Self.analyze(root: scanRoot, config: config)
        return CheckResult(
            checkerId: id,
            status: outcome.status,
            diagnostics: outcome.diagnostics,
            duration: ContinuousClock.now - startTime)
    }

    // MARK: - Engine (internal for tests)

    /// The manifest verdict for a project root.
    ///
    /// Skips a non-app target entirely; for an app, a missing or unparseable
    /// manifest is an error and a present manifest missing a top-level key is a
    /// warning.
    static func analyze(
        root: String,
        config: PrivacyManifestConfig
    ) -> (status: CheckResult.Status, diagnostics: [Diagnostic]) {
        let files = collectFiles(under: root)

        guard isApp(files: files, config: config) else {
            return (.skipped, [])
        }

        guard let manifest = files.first(where: { $0.lastPathComponent == "PrivacyInfo.xcprivacy" }) else {
            return (.failed, [Diagnostic(
                severity: .error,
                message: "App target is missing PrivacyInfo.xcprivacy — a privacy manifest is required for App Store submission.",
                filePath: root,
                ruleId: "privacy-manifest")])
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifest)
        } catch {
            // The error is not discarded here — it becomes the finding. It was, however,
            // reported without its cause, leaving "could not be read" to cover a
            // permissions problem, a broken symlink and a truncated file alike.
            // Logged as well as returned: the diagnostic reaches whoever reads the
            // report, the log reaches whoever is running the gate right now.
            Self.logger.debug(
                "privacy-manifest could not read \(manifest.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (.failed, [Diagnostic(
                severity: .error,
                message: "PrivacyInfo.xcprivacy could not be read: \(error.localizedDescription)",
                filePath: manifest.path,
                ruleId: "privacy-manifest")])
        }

        let diagnostics = validate(
            data: data,
            path: manifest.path,
            requireTopLevelKeys: config.requireTopLevelKeys)

        let status: CheckResult.Status
        if diagnostics.contains(where: { $0.severity == .error }) {
            status = .failed
        } else if diagnostics.contains(where: { $0.severity == .warning }) {
            status = .warning
        } else {
            status = .passed
        }
        return (status, diagnostics)
    }

    /// Validates a manifest's bytes: unparseable is an error; a parsed manifest
    /// missing an expected top-level key is a warning (when required).
    static func validate(
        data: Data,
        path: String,
        requireTopLevelKeys: Bool
    ) -> [Diagnostic] {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            // Again the finding carries the failure, but a plist parse error names the
            // byte offset and the malformation — which is the difference between "fix
            // your manifest" and "fix line 12".
            Self.logger.debug(
                "privacy-manifest could not parse \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return [Diagnostic(
                severity: .error,
                message: "PrivacyInfo.xcprivacy is not a valid property list: \(error.localizedDescription)",
                filePath: path,
                ruleId: "privacy-manifest")]
        }
        guard let dictionary = object as? [String: Any] else {
            return [Diagnostic(
                severity: .error,
                message: "PrivacyInfo.xcprivacy is a property list but not a dictionary.",
                filePath: path,
                ruleId: "privacy-manifest")]
        }

        guard requireTopLevelKeys else { return [] }

        return requiredKeys
            .filter { dictionary[$0] == nil }
            .map { key in
                Diagnostic(
                    severity: .warning,
                    message: "PrivacyInfo.xcprivacy is missing top-level key '\(key)'.",
                    filePath: path,
                    ruleId: "privacy-manifest")
            }
    }

    // MARK: - App detection

    /// True if the project positively presents as an app target: an explicit
    /// `appTargets` override, an `Info.plist` with app markers, or an
    /// `.xcodeproj` declaring an application product type.
    static func isApp(files: [URL], config: PrivacyManifestConfig) -> Bool {
        if !config.appTargets.isEmpty { return true }

        for url in files where url.lastPathComponent == "Info.plist" {
            if infoPlistHasAppMarkers(url) { return true }
        }

        for url in files where url.pathExtension == "pbxproj" {
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                // Not merely "no signal". This decides whether the target is an app, and
                // a false negative means the privacy-manifest check never runs — a
                // compliance gap that looks exactly like a clean pass.
                Self.logger.warning(
                    "privacy-manifest could not read \(url.lastPathComponent, privacy: .public) during app detection; the check may not apply when it should: \(error.localizedDescription, privacy: .public)")
                continue
            }
            if text.contains("com.apple.product-type.application") { return true }
        }

        return false
    }

    /// True if an `Info.plist` carries the markers of an application bundle:
    /// an executable name plus a launch screen or scene manifest.
    static func infoPlistHasAppMarkers(_ url: URL) -> Bool {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Self.logger.warning(
                "privacy-manifest could not read Info.plist at \(url.path, privacy: .public) during app detection; the check may not apply when it should: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            Self.logger.warning(
                "privacy-manifest could not parse Info.plist at \(url.path, privacy: .public) during app detection; the check may not apply when it should: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard let dictionary = object as? [String: Any] else { return false }
        return dictionary["CFBundleExecutable"] != nil
            && (dictionary["UILaunchScreen"] != nil || dictionary["UIApplicationSceneManifest"] != nil)
    }

    /// Every regular file under `root`, skipping hidden trees (`.build`, `.git`,
    /// DerivedData live under dot-directories) so scans stay fast and don't pick
    /// up vendored Info.plists.
    static func collectFiles(under root: String) -> [URL] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isRegular { files.append(url) }
        }
        return files
    }
}
