import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// `security.command-injection`, once it inspects arguments.
///
/// The rule was worded for injection — "validate and sanitize dynamic arguments", CWE-78 — and
/// its mechanism was `callee == "Process"`. It flagged every construction and never looked at an
/// argument, so it was disabled in configuration, which also removed the only signal pointing at
/// every direct spawn in the tree. That containment job now belongs to
/// `bounded-io.process-construction`; this is the other half of the split.
///
/// The distinction the rule now turns on: `Process` with an `arguments` array does **not** invoke
/// a shell — each element arrives as one `argv` entry, so a filename containing `; rm -rf /` is
/// passed as a filename. Injection needs an interpreter. The checkable property is a shell
/// invoked with `-c` and a command string that is not a literal.
///
/// See `quality-gate-swift-project/plans/proposals/CommandInjectionEarnsItsName.md`.
@Suite("security.command-injection")
struct CommandInjectionTests {

    private func audit(_ code: String) async throws -> CheckResult {
        var config = Configuration()
        config.security.enabledRules = ["security.command-injection"]
        return try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: config)
    }

    private func flagged(_ code: String) async throws -> Bool {
        try await audit(code).diagnostics.contains { $0.ruleId == "security.command-injection" }
    }

    // MARK: - Must flag: a shell handed an assembled command string

    @Test("/bin/sh -c with an interpolated command is flagged")
    func shellWithInterpolation() async throws {
        #expect(try await flagged("""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "grep \\(pattern) \\(file)"]
        """))
    }

    @Test("/bin/bash -lc with an interpolated command is flagged")
    func bashLoginShell() async throws {
        #expect(try await flagged("""
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-lc", "ls \\(directory)"]
        """))
    }

    @Test("env sh -c with an interpolated command is flagged")
    func envShell() async throws {
        #expect(try await flagged("""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["sh", "-c", "cat \\(path)"]
        """))
    }

    // MARK: - Must NOT flag

    /// A literal script is not injection: nothing was assembled.
    @Test("A shell with a literal command is not flagged")
    func shellWithLiteralCommand() async throws {
        #expect(!(try await flagged("""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "ls -la /tmp"]
        """)))
    }

    /// `git -c key=value` sets configuration. Present in this repository twice.
    @Test("git -c is not a shell and is not flagged")
    func gitDashC() async throws {
        #expect(!(try await flagged("""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-c", "user.name=\\(name)", "commit"]
        """)))
    }

    /// `swift build -c release` selects a configuration. Present in this repository.
    @Test("swift build -c is not a shell and is not flagged")
    func swiftBuildDashC() async throws {
        #expect(!(try await flagged("""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        task.arguments = ["build", "-c", "\\(configuration)"]
        """)))
    }

    /// The core distinction: an argv array invokes no interpreter.
    @Test("Interpolation into an argv element without a shell is not flagged")
    func argvInterpolationIsNotInjection() async throws {
        #expect(!(try await flagged("""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        task.arguments = ["grep", pattern, file]
        """)))
    }

    @Test("Interpolation into a non-command argument of a shell call is not flagged")
    func shellNonCommandArgument() async throws {
        #expect(!(try await flagged("""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["\\(scriptPath)"]
        """)))
    }

    // MARK: - Acknowledgement and configuration

    @Test("A // SECURITY: line records an override rather than a diagnostic")
    func securityMarkerOverrides() async throws {
        let result = try await audit("""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // SECURITY: the command is assembled from a compile-time constant table.
        task.arguments = ["-c", "grep \\(pattern) \\(file)"]
        """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.command-injection" })
        #expect(result.overrides.contains { $0.ruleId == "security.command-injection" })
    }

    @Test("The rule is silent when not enabled")
    func honoursRuleDisabling() async throws {
        var config = Configuration()
        config.security.enabledRules = ["security.weak-crypto"]
        let result = try await SafetyAuditor().auditSource("""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "grep \\(pattern) \\(file)"]
        """, fileName: "test.swift", configuration: config)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.command-injection" })
    }
}
