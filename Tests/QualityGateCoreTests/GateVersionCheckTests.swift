import Foundation
import Testing
@testable import QualityGateCore

@Suite("Stale-binary self-check (0.6)")
struct GateVersionCheckTests {

    @Test("no pin configured is always satisfied")
    func noPin() {
        #expect(GateVersionCheck.check(minimum: nil, buildDate: "2026-07-09T18:00:08Z") == .noPin)
    }

    @Test("a binary built after the pin satisfies it", arguments: [
        "2026-07-01",
        "2026-07-09",
        "2026-07-09T18:00:08Z",
        "2026-07-09T17:59:00Z",
    ])
    func pinSatisfied(pin: String) {
        #expect(GateVersionCheck.check(minimum: pin, buildDate: "2026-07-09T18:00:08Z") == .satisfied)
    }

    @Test("a binary older than the pin is stale, naming both versions", arguments: [
        "2026-07-10",
        "2026-08-01T00:00:00Z",
    ])
    func pinViolated(pin: String) {
        let outcome = GateVersionCheck.check(minimum: pin, buildDate: "2026-07-09T18:00:08Z")
        #expect(outcome == .stale(installed: "2026-07-09T18:00:08Z", required: pin))
    }

    @Test("an unparseable pin is surfaced, not silently passed")
    func unparseablePin() {
        let outcome = GateVersionCheck.check(minimum: "latest", buildDate: "2026-07-09T18:00:08Z")
        #expect(outcome == .unparseablePin("latest"))
    }

    @Test("an unparseable build date (dev builds) never blocks")
    func unparseableBuildDate() {
        let outcome = GateVersionCheck.check(minimum: "2026-07-01", buildDate: "unknown")
        #expect(outcome == .satisfied)
    }

    @Test("minimumGateVersion decodes from YAML and defaults to nil")
    func configKey() throws {
        #expect(Configuration().minimumGateVersion == nil)

        let tempDir = FileManager.default.temporaryDirectory
        let configPath = tempDir.appendingPathComponent(".quality-gate-pin-\(UUID().uuidString).yml")
        try "minimumGateVersion: \"2026-07-01\"\n".write(to: configPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: configPath) // silent: best-effort temp cleanup
        }
        let config = try Configuration.load(from: configPath.path)
        #expect(config.minimumGateVersion == "2026-07-01")
    }
}
