import ArgumentParser
import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// One-stop staleness diagnostic (Phase 0.6): build identity, config
/// provenance, minimumGateVersion pin status, and index freshness.
struct Doctor: AsyncParsableCommand {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "Doctor")

    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Print gate build identity, config provenance, version-pin status, and index freshness."
    )

    @Option(name: .long, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    func run() async throws {
        print("quality-gate doctor")
        print("═══════════════════════════════════════════════")

        // Build identity — the staleness question everything else hangs on.
        print("Build:")
        print("  commit:     \(BuildStamp.gitCommit)")
        print("  built:      \(BuildStamp.buildDate)")
        print("  binary:     \(CheckerFingerprint.runningExecutablePath())")

        // Config provenance (Phase 1's overlay model reuses this line).
        print("Config:")
        let fm = FileManager.default
        let loadedConfiguration: Configuration
        if fm.fileExists(atPath: config) { // SAFETY: read-only check on configured path
            do {
                loadedConfiguration = try Configuration.load(from: config)
                print("  source:     \(config)")
            } catch {
                Self.logger.warning("doctor.config-unparseable: \(error.localizedDescription, privacy: .public)")
                loadedConfiguration = Configuration()
                print("  source:     \(config) (unparseable: \(error.localizedDescription)) — defaults in effect")
            }
        } else {
            loadedConfiguration = Configuration()
            print("  source:     built-in defaults (\(config) not found)")
        }

        // Pin status against this binary.
        print("Version pin:")
        switch GateVersionCheck.check(minimum: loadedConfiguration.minimumGateVersion, buildDate: BuildStamp.buildDate) {
        case .noPin:
            print("  status:     no minimumGateVersion configured")
        case .satisfied:
            print("  status:     ✓ binary satisfies minimumGateVersion \(loadedConfiguration.minimumGateVersion ?? "")")
        case .stale(let installed, let required):
            print("  status:     ✗ STALE — binary built \(installed), repo requires \(required)")
            print("              Rebuild and reinstall the gate (make install).")
        case .unparseablePin(let pin):
            print("  status:     ⚠ minimumGateVersion '\(pin)' is not a date (YYYY-MM-DD or ISO8601)")
        }

        // Index freshness — reported, never rebuilt from here.
        print("Index store:")
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            "\(cwd)/.build/debug/index/store",
            "\(cwd)/.build/arm64-apple-macosx/debug/index/store",
            "\(cwd)/.build/x86_64-apple-macosx/debug/index/store",
        ]
        if let store = candidates.first(where: { fm.fileExists(atPath: $0) }) { // SAFETY: read-only checks in project dir
            let age: String
            if let attrs = try? fm.attributesOfItem(atPath: store), // silent: missing mtime just means age is unknown
               let mtime = attrs[.modificationDate] as? Date {
                let hours = ((Date().timeIntervalSince(mtime) / 3600) * 10).rounded() / 10
                age = "\(hours) hour(s) old"
            } else {
                age = "age unknown"
            }
            print("  store:      \(store)")
            print("  freshness:  \(age)")
        } else {
            print("  store:      none found under .build/ (index-backed checkers will degrade to AST-only)")
        }
    }
}
