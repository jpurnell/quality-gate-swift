import Foundation
#if canImport(os)
import os
#endif

/// The flags the active toolchain needs in order to typecheck a documentation block the
/// same way the package's own build would.
///
/// Probed once and reused. Every entry here exists because its absence produced a
/// *documentation* finding for a *tooling* fact — the failure mode worth designing against,
/// because the natural response is to mark the block illustrative and the workaround then
/// looks exactly like compliance.
public enum Toolchain {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocCodeAuditor")

    /// The probe's result, computed lazily by the runtime's own thread-safe global
    /// initialisation, so concurrent article audits share it without coordination and
    /// without spawning `xcrun` once per article.
    private static let cached: [String] = probe()

    /// SDK, platform frameworks and macro plugin path for the active toolchain.
    public static func flags() -> [String] { cached }

    /// The platform's Developer frameworks directory, or `nil` when the probe found none.
    ///
    /// Recovered from the probed flags rather than probed a second time, so the path an
    /// article is *linked* against is by construction the same one it was *typechecked*
    /// against. Rung 1 needs it as `-F`; rung 2 needs the same directory again as an
    /// `-rpath`, because `Testing.framework` is loaded by name at launch and a program that
    /// typechecks against a framework it cannot find at run time dies with
    /// `Library not loaded` — a tooling fact that looks exactly like a documentation defect.
    public static func platformFrameworkPath() -> String? {
        guard let index = cached.firstIndex(of: "-F"), index + 1 < cached.count else { return nil }
        return cached[index + 1]
    }

    /// Probes `xcrun` for the paths this checker needs.
    static func probe() -> [String] {
        var flags: [String] = []

        if let sdk = run(["--show-sdk-path"]) {
            flags += ["-sdk", sdk]
        }

        // swift-testing lives in the platform's Developer frameworks, and its `@Test` and
        // `#expect` macros need the host plugin. Without both, every testing block fails —
        // first `no such module 'Testing'`, then a missing `TestingMacros` implementation —
        // and neither is a defect in the documentation.
        if let platform = run(["--show-sdk-platform-path"]) {
            let frameworks = platform + "/Developer/Library/Frameworks"
            // SAFETY: CLI tool probes the toolchain's own framework directory
            if FileManager.default.fileExists(atPath: frameworks) {
                flags += ["-F", frameworks]
            }
        }

        if let swiftc = run(["-f", "swiftc"]) {
            let usr = URL(fileURLWithPath: swiftc)
                .deletingLastPathComponent()          // …/usr/bin
                .deletingLastPathComponent()          // …/usr

            let plugins = usr.appendingPathComponent("lib/swift/host/plugins/testing").path
            // SAFETY: CLI tool probes the toolchain's own plugin directory
            if FileManager.default.fileExists(atPath: plugins) {
                flags += ["-plugin-path", plugins]
            }

            // `PackageDescription` ships beside the toolchain rather than in the SDK, so it
            // is on no target's module search path. Without this, every documented
            // `Package.swift` excerpt fails — and the natural response is to mark those
            // blocks illustrative, which is a false clean: the gate would have manufactured
            // an exemption for a manifest snippet it simply could not reach.
            let manifestAPI = usr.appendingPathComponent("lib/swift/pm/ManifestAPI").path
            // SAFETY: CLI tool probes the toolchain's own manifest API directory
            if FileManager.default.fileExists(atPath: manifestAPI) {
                flags += ["-I", manifestAPI]
            }
        }

        return flags
    }

    /// Runs `xcrun` with `arguments`, returning its trimmed output.
    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        // SAFETY: subprocess with hardcoded `/usr/bin/xcrun` and fixed query arguments
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        } catch {
            logger.warning("Could not probe the toolchain via xcrun \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
