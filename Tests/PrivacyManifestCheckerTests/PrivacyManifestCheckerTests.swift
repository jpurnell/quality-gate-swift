import Foundation
import Testing
import QualityGateCore
@testable import PrivacyManifestChecker

/// The `privacy-manifest` checker (PrivacyManifestChecker proposal, Phase 0).
///
/// Contract under test: the checker acts only on a positively-detected app
/// target (Info.plist app markers, or an `appTargets` override) — a pure SPM
/// library is `.skipped`. For an app: a missing manifest or an unparseable one
/// is a `.failed` error; a valid manifest missing a top-level key is a
/// `.warning`; a complete manifest is `.passed`.
@Suite("PrivacyManifestChecker")
struct PrivacyManifestCheckerTests {

    // MARK: - Fixtures

    private static let appInfoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleExecutable</key><string>MyApp</string>
        <key>UILaunchScreen</key><dict/>
    </dict>
    </plist>
    """

    private static func manifest(includeAccessedAPIs: Bool = true) -> String {
        let accessed = includeAccessedAPIs
            ? "<key>NSPrivacyAccessedAPITypes</key><array/>"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>NSPrivacyTracking</key><false/>
            <key>NSPrivacyTrackingDomains</key><array/>
            <key>NSPrivacyCollectedDataTypes</key><array/>
            \(accessed)
        </dict>
        </plist>
        """
    }

    /// Writes `files` (relative path → contents) into a fresh temp dir, runs the
    /// engine, and cleans up.
    private func run(
        _ files: [String: String],
        config: PrivacyManifestConfig = PrivacyManifestConfig()
    ) throws -> (status: CheckResult.Status, diagnostics: [Diagnostic]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pmc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (relative, contents) in files {
            let fileURL = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return PrivacyManifestChecker.analyze(root: root.path, config: config)
    }

    // MARK: - App detection & skip

    @Test("a pure SPM library (no app markers) is skipped, even with no manifest")
    func libraryIsSkipped() throws {
        let result = try run(["Package.swift": "// swift-tools-version:6.0"])
        #expect(result.status == .skipped)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("an app target with no manifest fails with an error")
    func appMissingManifest() throws {
        let result = try run([
            "MyApp/Info.plist": Self.appInfoPlist,
            "MyApp/App.swift": "import SwiftUI",
        ])
        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.severity == .error })
        #expect(try #require(result.diagnostics.first).ruleId == "privacy-manifest")
    }

    @Test("appTargets config forces app-mode on an otherwise-ambiguous project")
    func appTargetsForcesAppMode() throws {
        let result = try run(
            ["Sources/Thing.swift": "let x = 1"],
            config: PrivacyManifestConfig(appTargets: ["MyApp"]))
        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.severity == .error })
    }

    // MARK: - Manifest validation

    @Test("an app with a complete valid manifest passes")
    func appValidManifest() throws {
        let result = try run([
            "MyApp/Info.plist": Self.appInfoPlist,
            "MyApp/PrivacyInfo.xcprivacy": Self.manifest(),
        ])
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("a manifest missing a top-level key warns, not errors")
    func appManifestMissingKey() throws {
        let result = try run([
            "MyApp/Info.plist": Self.appInfoPlist,
            "MyApp/PrivacyInfo.xcprivacy": Self.manifest(includeAccessedAPIs: false),
        ])
        #expect(result.status == .warning)
        #expect(result.diagnostics.contains { $0.severity == .warning })
        #expect(!result.diagnostics.contains { $0.severity == .error })
        #expect(try #require(result.diagnostics.first).message.contains("NSPrivacyAccessedAPITypes"))
    }

    @Test("an unparseable manifest fails with an error")
    func appMalformedManifest() throws {
        let result = try run([
            "MyApp/Info.plist": Self.appInfoPlist,
            "MyApp/PrivacyInfo.xcprivacy": "this is not a plist {{{",
        ])
        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.severity == .error })
    }

    @Test("requireTopLevelKeys=false accepts a present but sparse manifest")
    func topLevelKeysNotRequired() throws {
        let sparse = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict/></plist>
        """
        let result = try run([
            "MyApp/Info.plist": Self.appInfoPlist,
            "MyApp/PrivacyInfo.xcprivacy": sparse,
        ], config: PrivacyManifestConfig(requireTopLevelKeys: false))
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }
}
