import Foundation
import QualityGateCore
import QualityGateLogging

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

        // SAFETY: CLI tool probes PATH for the compiler the build itself resolves
        let onPath = swiftcOnPath(
            path: ProcessInfo.processInfo.environment["PATH"],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            isToolchainRoot: { hasToolchainLayout(usr: $0) })

        if let swiftc = onPath ?? run(["-f", "swiftc"]) {
            let usr = URL(fileURLWithPath: swiftc)
                .deletingLastPathComponent()          // …/usr/bin
                .deletingLastPathComponent()          // …/usr

            // Two layouts, because the macro plugins do not live in the same place on every
            // platform. An Xcode toolchain nests them under `plugins/testing`; a swift.org
            // Linux toolchain puts them directly in `plugins`. Probing only the first meant
            // `-plugin-path` was silently omitted on Linux — and silently is the problem:
            // every fence using a Swift Testing macro then fails to expand, `doc-claims`
            // cannot compile the assertions it injects, and the checker reports no claims
            // rather than reporting that it could not check them. Measured in CI: the
            // container has `/usr/lib/swift/pm/ManifestAPI` but no `host/plugins/testing`.
            //
            // Both are added when both exist. A path that is not there contributes nothing,
            // and the compiler ignores a `-plugin-path` it finds no plugins in.
            for candidate in ["lib/swift/host/plugins/testing", "lib/swift/host/plugins"] {
                let plugins = usr.appendingPathComponent(candidate).path
                // SAFETY: CLI tool probes the toolchain's own plugin directory
                if FileManager.default.fileExists(atPath: plugins) {
                    flags += ["-plugin-path", plugins]
                }
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

    /// The `swiftc` on `PATH`, or `nil` when there is none.
    ///
    /// Preferred over `xcrun -f swiftc`, because those two can be *different compilers*.
    /// `xcrun` answers with Xcode's toolchain; a CI job that installs its own puts that one on
    /// `PATH` and leaves Xcode's where `xcrun` finds it. The module this checker imports is
    /// whatever `swift build` produced, and `swift build` resolves through `PATH` — so the
    /// plugin and manifest directories have to be read from the same place, or a block is
    /// typechecked by a compiler that cannot load the module it imports. That failure arrives
    /// as `no such module`, indistinguishable from a documentation defect.
    ///
    /// `xcrun` remains the fallback: a `PATH` without `swiftc` is the normal shape on a machine
    /// where only Xcode provides one.
    ///
    /// Being executable is not enough: `/usr/bin/swiftc` is a shim present on every Mac and
    /// first on `PATH`, and the directory two levels above it is `/usr`, which holds neither
    /// the testing plugins nor `ManifestAPI`. Accepting it would drop `-plugin-path` and
    /// `-I <ManifestAPI>` from every compile, so a documented `@Test` block would fail on
    /// `no such module 'Testing'` — the same class of tooling-as-defect this function exists
    /// to remove. Candidates are therefore scanned until one is a real toolchain root, and a
    /// `PATH` offering only shims resolves to `nil` so `xcrun` still answers.
    ///
    /// - Parameters:
    ///   - path: A colon-separated `PATH`, or `nil` when the variable is unset.
    ///   - isExecutable: Answers whether a candidate path is an executable file.
    ///   - isToolchainRoot: Answers whether a candidate's `usr` directory is a toolchain,
    ///     holding the plugin or manifest directories this checker came for.
    /// - Returns: The first `swiftc` on `path` that is both executable and a real toolchain,
    ///   or `nil` when there is none.
    static func swiftcOnPath(
        path: String?,
        isExecutable: (String) -> Bool,
        isToolchainRoot: (String) -> Bool
    ) -> String? {
        guard let path else { return nil }

        // Empty entries are dropped rather than probed: a bare `:` in PATH means the current
        // directory to a shell, and resolving it here would offer `/swiftc` to `isExecutable`.
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(entry))
                .appendingPathComponent("swiftc")
            guard isExecutable(candidate.path) else { continue }

            let usr = candidate
                .deletingLastPathComponent()          // …/usr/bin
                .deletingLastPathComponent()          // …/usr
            if isToolchainRoot(usr.path) { return candidate.path }
        }
        return nil
    }

    /// Whether `usr` holds either directory this checker derives from a toolchain.
    ///
    /// An `or` rather than an `and`: a toolchain without `ManifestAPI` still supplies the
    /// testing plugins, and requiring both would reject it for the half it does have.
    private static func hasToolchainLayout(usr: String) -> Bool {
        let base = URL(fileURLWithPath: usr)
        // SAFETY: CLI tool probes a candidate toolchain's own directories
        return FileManager.default.fileExists(
            atPath: base.appendingPathComponent("lib/swift/host/plugins/testing").path)
            // SAFETY: CLI tool probes a candidate toolchain's own directories
            || FileManager.default.fileExists(
                atPath: base.appendingPathComponent("lib/swift/pm/ManifestAPI").path)
    }

    /// Runs `xcrun` with `arguments`, returning its trimmed output.
    private static func run(_ arguments: [String]) -> String? {
        // Through the kernel: `xcrun` can block indefinitely resolving a toolchain, and a query
        // for a compiler flag must not be able to hang the whole run.
        do {
            // SAFETY: subprocess with hardcoded `/usr/bin/xcrun` and fixed query arguments
            let result = try ProcessRunner.run(
                "/usr/bin/xcrun", arguments: arguments, timeout: 60)
            guard result.exitCode == 0 else { return nil }
            let value = result.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch {
            logger.warning("Could not probe the toolchain via xcrun \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
