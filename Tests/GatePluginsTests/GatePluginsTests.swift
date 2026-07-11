import Foundation
import Testing
@testable import GatePlugins
@testable import QualityGateCore

/// Phase 4b — the Tier-2 plugin runner and its trust rules.
///
/// Fixture plugins are tiny shell scripts written per test: the contract is
/// "any executable speaking JSON over stdio", so the fixtures prove exactly
/// that — no Swift required on the plugin side.
@Suite("GatePlugins", .serialized)
struct GatePluginsTests {

    // MARK: - Fixtures

    private func writeScript(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fixture-plugin").path
        try "#!/bin/bash\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private static let descriptorJSON =
        #"{"contractVersion":1,"checkerId":"fixture","name":"fixture-plugin","parallelSafe":true}"#

    private static let failingResultJSON =
        #"{"checkerId":"fixture","status":"failed","diagnostics":[{"severity":"error","message":"planted","ruleId":"fixture.rule"}],"overrides":[],"complianceRecords":[],"duration":[0,1000000]}"#

    /// A well-behaved plugin that reports one planted error.
    private func makeHealthyPlugin() throws -> String {
        try writeScript("""
        case "$1" in
          contract) echo '\(Self.descriptorJSON)' ;;
          check) cat > /dev/null; echo '\(Self.failingResultJSON)' ;;
        esac
        """)
    }

    // MARK: - Resolution & handshake

    @Test("explicit run path resolves; a missing one does not")
    func resolution() throws {
        let path = try makeHealthyPlugin()
        #expect(PluginRunner.resolveExecutable(
            for: PluginConfig(name: "fixture", run: path)) == path)
        #expect(PluginRunner.resolveExecutable(
            for: PluginConfig(name: "fixture", run: "/nonexistent/plugin")) == nil)
    }

    @Test("PATH discovery finds quality-gate-plugin-<name>")
    func pathDiscovery() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("quality-gate-plugin-fixture").path
        try "#!/bin/bash\necho hi\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        let resolved = PluginRunner.resolveExecutable(
            for: PluginConfig(name: "fixture"),
            environment: ["PATH": dir.path])
        #expect(resolved == path)
    }

    @Test("the handshake decodes a descriptor")
    func handshake() throws {
        let path = try makeHealthyPlugin()
        let descriptor = PluginRunner.describe(executable: path)
        #expect(descriptor == PluginDescriptor(
            contractVersion: 1, checkerId: "fixture",
            name: "fixture-plugin", parallelSafe: true))
    }

    // MARK: - Trust rules

    @Test("advisory by default: a plugin error cannot fail the gate")
    func advisoryCannotGate() async throws {
        let path = try makeHealthyPlugin()
        let checker = PluginChecker(plugin: PluginConfig(name: "fixture", run: path))
        let result = try await checker.check(configuration: Configuration())
        #expect(result.status == .passed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].severity == .note)
        #expect(result.diagnostics[0].message == "planted")
        #expect(result.diagnostics[0].origin == "plugin/fixture")
    }

    @Test("gates: true lets the plugin fail the gate, provenance intact")
    func gatingPluginCanFail() async throws {
        let path = try makeHealthyPlugin()
        let checker = PluginChecker(
            plugin: PluginConfig(name: "fixture", run: path, gates: true))
        let result = try await checker.check(configuration: Configuration())
        #expect(result.status == .failed)
        #expect(result.diagnostics[0].severity == .error)
        #expect(result.diagnostics[0].origin == "plugin/fixture")
    }

    // MARK: - Failure modes → plugin-error, never a crash

    @Test("garbage output is a plugin-error finding")
    func garbageOutput() async throws {
        let path = try writeScript("""
        case "$1" in
          contract) echo '\(Self.descriptorJSON)' ;;
          check) cat > /dev/null; echo 'not json at all' ;;
        esac
        """)
        let checker = PluginChecker(plugin: PluginConfig(name: "fixture", run: path))
        let result = try await checker.check(configuration: Configuration())
        #expect(result.status == .passed)
        #expect(result.diagnostics[0].ruleId == "plugin-error")
        #expect(result.diagnostics[0].message.contains("not a CheckResult"))
    }

    @Test("a timeout terminates the plugin and reports the budget")
    func timeout() async throws {
        let path = try writeScript("""
        case "$1" in
          contract) echo '\(Self.descriptorJSON)' ;;
          check) cat > /dev/null; sleep 30 ;;
        esac
        """)
        let checker = PluginChecker(
            plugin: PluginConfig(name: "fixture", run: path, timeoutSeconds: 1))
        let result = try await checker.check(configuration: Configuration())
        #expect(result.status == .passed)
        #expect(result.diagnostics[0].ruleId == "plugin-error")
        #expect(result.diagnostics[0].message.contains("1s budget"))
    }

    @Test("a non-zero exit is a plugin-error finding; gating makes it fail")
    func nonZeroExit() async throws {
        let path = try writeScript("""
        case "$1" in
          contract) echo '\(Self.descriptorJSON)' ;;
          check) cat > /dev/null; echo boom; exit 3 ;;
        esac
        """)
        let advisory = PluginChecker(plugin: PluginConfig(name: "fixture", run: path))
        let advisoryResult = try await advisory.check(configuration: Configuration())
        #expect(advisoryResult.status == .passed)
        #expect(advisoryResult.diagnostics[0].ruleId == "plugin-error")

        let gating = PluginChecker(
            plugin: PluginConfig(name: "fixture", run: path, gates: true))
        let gatingResult = try await gating.check(configuration: Configuration())
        #expect(gatingResult.status == .failed)
        #expect(gatingResult.diagnostics[0].severity == .error)
    }

    @Test("a newer contract version is skipped visibly, never guessed")
    func newerContractSkips() async throws {
        let path = try writeScript("""
        case "$1" in
          contract) echo '{"contractVersion":99,"checkerId":"fixture","name":"fixture-plugin","parallelSafe":true}' ;;
        esac
        """)
        let checker = PluginChecker(plugin: PluginConfig(name: "fixture", run: path))
        let result = try await checker.check(configuration: Configuration())
        #expect(result.status == .skipped)
        #expect(result.diagnostics[0].message.contains("v99"))
    }

    @Test("plugins: config section decodes with defaults")
    func configDecodes() throws {
        let yaml = """
        plugins:
          - name: swift-vigil
            run: /usr/local/bin/vigil
            config: { strict: true }
          - name: bare
        """
        let configuration = try Configuration.from(yaml: yaml)
        #expect(configuration.plugins.count == 2)
        #expect(configuration.plugins[0].name == "swift-vigil")
        #expect(configuration.plugins[0].gates == false)
        #expect(configuration.plugins[0].timeoutSeconds == 60)
        #expect(configuration.plugins[1].run == nil)
    }
}
