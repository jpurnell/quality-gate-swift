import Foundation
import Testing
@testable import QualityGateCore

// A `soak:` block that is written down and then ignored would drop the release requirement it states, so every
// mistake in it stops the run and says what would be accepted. An absent block requires nothing.

@Suite("soak: the release soak requirement")
struct SoakConfigTests {

    @Test("an absent block requires nothing, so no existing project's gate changes")
    func absent() throws {
        let configuration = try Configuration.from(yaml: "enabledCheckers: []\n")
        #expect(configuration.soak == .default)
        #expect(configuration.soak.requiredFor.isEmpty)
        #expect(configuration.unknownKeys == nil)
    }

    @Test("the defaults are the calibrated rule")
    func defaults() {
        let soak = SoakConfig.default
        #expect(soak.preWarmMinutes == 30)
        #expect(soak.windowMinutes == 60)
        #expect(soak.slopeLimitMBPerHour == 2)
        #expect(soak.descriptorDriftLimit == 8)
        #expect(soak.minSeconds == 5400)
        #expect(soak.maxAgeDays == 14)
        #expect(soak.intervalSeconds == 30)
        #expect(soak.requireDrain)
        #expect(soak.sources == ["Sources/**", "Package.swift", "Package.resolved"])
        #expect(soak.waiver == nil)
    }

    @Test("every key is read")
    func everyKey() throws {
        let configuration = try Configuration.from(yaml: """
            soak:
              requiredFor: [major, minor]
              minSeconds: 9000
              maxAgeDays: 7
              intervalSeconds: 60
              requireDrain: false
              sources: ["Sources/**"]
              preWarmMinutes: 45
              windowMinutes: 90
              slopeLimitMBPerHour: 1.5
              descriptorDriftLimit: 4
              waiver: { version: "1.2.0", reason: "docs only", date: "2026-12-01" }
            """)
        let soak = configuration.soak
        #expect(soak.requiredFor == ["major", "minor"])
        #expect(soak.minSeconds == 9000)
        #expect(soak.maxAgeDays == 7)
        #expect(soak.intervalSeconds == 60)
        #expect(!soak.requireDrain)
        #expect(soak.sources == ["Sources/**"])
        #expect(soak.preWarmMinutes == 45)
        #expect(soak.windowMinutes == 90)
        #expect(soak.slopeLimitMBPerHour.isEqual(to: 1.5))
        #expect(soak.descriptorDriftLimit == 4)
        #expect(soak.waiver == SoakConfig.Waiver(version: "1.2.0", reason: "docs only", date: "2026-12-01"))
    }

    @Test("a minimum that cannot cover the pre-warm and the window is refused, with the figure that would")
    func minimumTooShort() {
        #expect(throws: SoakConfig.Invalid.minSecondsBelowWindow(minSeconds: 1500, needed: 5400)) {
            try Configuration.from(yaml: "soak:\n  requiredFor: [minor]\n  minSeconds: 1500\n")
        }
    }

    @Test("a tag class that does not exist is refused, naming the ones that do")
    func unknownTagClass() {
        #expect(throws: SoakConfig.Invalid.unknownTagClass("majr")) {
            try Configuration.from(yaml: "soak:\n  requiredFor: [majr]\n")
        }
    }

    @Test("a key the block does not have is refused, so a misspelt requirement cannot go quiet")
    func unknownKey() {
        #expect(throws: SoakConfig.Invalid.unknownKey("requireFor")) {
            try Configuration.from(yaml: "soak:\n  requireFor: [major]\n")
        }
    }

    @Test("a figure that is not a positive finite number is refused")
    func notPositive() {
        #expect(throws: SoakConfig.Invalid.notPositive(key: "windowMinutes", value: 0)) {
            try Configuration.from(yaml: "soak:\n  windowMinutes: 0\n")
        }
        #expect(throws: SoakConfig.Invalid.notPositive(key: "slopeLimitMBPerHour", value: -1)) {
            try Configuration.from(yaml: "soak:\n  slopeLimitMBPerHour: -1\n")
        }
        #expect(throws: SoakConfig.Invalid.notPositive(key: "maxAgeDays", value: 0)) {
            try Configuration.from(yaml: "soak:\n  maxAgeDays: 0\n")
        }
    }

    @Test("a window or pre-warm too large to be a duration is refused rather than trapping in a conversion")
    func tooLarge() {
        #expect(throws: SoakConfig.Invalid.outOfRange(key: "windowMinutes", value: 1e300, maximum: SoakConfig.maximumMinutes)) {
            try Configuration.from(yaml: "soak:\n  windowMinutes: 1e300\n")
        }
        #expect(throws: SoakConfig.Invalid.outOfRange(key: "preWarmMinutes", value: 600_000, maximum: SoakConfig.maximumMinutes)) {
            try Configuration.from(yaml: "soak:\n  preWarmMinutes: 600000\n")
        }
    }

    @Test("an empty `sources` list is refused: it would select nothing to digest")
    func noSources() {
        #expect(throws: SoakConfig.Invalid.noSources) {
            try Configuration.from(yaml: "soak:\n  sources: []\n")
        }
    }

    @Test("a refusal keeps its type when the configuration is loaded from a file, so it cannot be run past with defaults")
    func loadKeepsTheRefusal() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("soak-config-\(UUID().uuidString).yml").path
        try "soak:\n  requiredFor: [majr]\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: SoakConfig.Invalid.unknownTagClass("majr")) { try Configuration.load(from: path) }
    }
}
