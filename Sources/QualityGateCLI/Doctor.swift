import ArgumentParser
import Foundation
#if canImport(os)
import os
#endif
import IndexStoreInfra
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

        // Config provenance — layered resolution (Phase 1): repo → overlay
        // → user-global → built-in, attributed per section.
        print("Config:")
        let fm = FileManager.default
        let loadedConfiguration: Configuration
        do {
            let resolution = try LayeredConfig.resolve(repoConfigPath: config)
            loadedConfiguration = resolution.configuration
            for line in resolution.provenance.renderTable().split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                print("  \(line)")
            }
        } catch {
            Self.logger.warning("doctor.config-unparseable: \(error.localizedDescription, privacy: .public)")
            loadedConfiguration = Configuration()
            print("  source:     \(config) (unparseable: \(error.localizedDescription)) — defaults in effect")
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
        // Asked, not guessed. This used to hold its own list of three paths that
        // `StoreLocator` has never written to, so it reported "none found" on a checkout
        // whose store held 2,572 units and was being queried by three checkers in the
        // same run. `locateExisting` consults the real candidates and never builds.
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let store = StoreLocator.locateExisting(packageRoot: packageRoot) {
            // Age is measured on `v5/units`, which is what `freshSwiftbuildStore` compares
            // against the newest source — not on the store root. Those differ by weeks:
            // `.build/out` here was last touched on 4 August while its units were written
            // twelve seconds after the newest source. Reporting the root's mtime said
            // "407 hours old" about a store that was current, which is the kind of false
            // alarm that sends someone off to rebuild something that was already right.
            let units = StoreLocator.unitsDirectory(in: store)
            let age: String
            if let mtime = StoreLocator.mtime(of: units) {
                let hours = ((Date().timeIntervalSince(mtime) / 3600) * 10).rounded() / 10
                age = "\(hours) hour(s) old"
            } else {
                age = "age unknown"
            }
            print("  store:      \(store.path)")
            print("  freshness:  \(age)")

            // Existence is not usefulness. A store whose build failed before reaching the
            // package's own Swift code holds only Clang module units, passes every
            // freshness check, and answers nothing — which is exactly what one surveyed
            // package turned out to have. The count is the honest signal.
            // Deliberately optional, unlike the shared helper: doctor reports "unreadable"
            // to the user as a distinct outcome from "empty", and flattening the two would
            // lose exactly the signal this block exists to print.
            let unitCount: Int?
            do {
                unitCount = try FileManager.default.contentsOfDirectory(atPath: units.path).count
            } catch {
                Self.logger.debug(
                    "doctor could not list index units at \(units.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                unitCount = nil
            }
            if let unitCount {
                print("  units:      \(unitCount)")
                if unitCount == 0 {
                    print("              (empty — index-backed checkers will degrade to AST-only)")
                }
            } else {
                print("  units:      unreadable at \(units.path)")
            }
        } else {
            print("  store:      none found (index-backed checkers will degrade to AST-only)")
            print("              looked for \(StoreLocator.managedStore(packageRoot: packageRoot).path)")
        }
    }
}
