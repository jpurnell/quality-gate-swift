import Foundation
import Testing
@testable import ReleaseReadinessAuditor

private let digest = String(repeating: "a", count: 64)
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func samples(
    minutes: Double = 100,
    footprint: (Double) -> Double = { 20 + sin($0) * 0.01 },
    descriptors: (Double) -> Int = { _ in 12 }
) -> [SoakSample] {
    stride(from: 22.0, to: minutes * 60, by: 30).map {
        SoakSample(t: $0, footprintMB: footprint($0 / 60), descriptors: descriptors($0 / 60))
    }
}

/// A result sealed over `samples`, ending a day before `now`, that should raise no finding.
private func result(
    samples s: [SoakSample] = samples(),
    sourceDigest: String = digest,
    durationSeconds: Int = 6000,
    endedAt: Date = now.addingTimeInterval(-86_400),
    drain: SoakDrain? = SoakDrain(exitCode: 0, seconds: 3),
    sealed: SoakEvaluation? = nil
) -> SoakResult {
    SoakResult(
        schemaVersion: SoakResult.currentSchemaVersion, package: "Demo", sourceDigest: sourceDigest,
        startedAt: endedAt.addingTimeInterval(-Double(durationSeconds)), endedAt: endedAt,
        durationSeconds: durationSeconds, host: "Chromedome", toolchain: "Swift 6.4.2", intervalSeconds: 30,
        architecture: "x86_64", samples: s, drain: drain, reloaded: true,
        sealed: sealed ?? SoakJudgement.judge(samples: s, architecture: "x86_64", limits: .calibrated))
}

private let required = SoakRelease(requiredFor: [.major, .minor], minSeconds: 5400, maxAgeDays: 14, requireDrain: true,
                                   limits: .calibrated, waiver: nil)

private func ids(_ r: SoakReport) -> [String] { r.findings.map(\.ruleId) }

@Suite("Soak tag classes")
struct SoakTagClassTests {
    @Test("a tag is a major, minor, patch or prerelease")
    func classify() {
        #expect(SoakTagClass(tag: "v2.0.0") == .major)
        #expect(SoakTagClass(tag: "2.1.0") == .minor)
        #expect(SoakTagClass(tag: "v2.1.3") == .patch)
        #expect(SoakTagClass(tag: "v2.1.0-beta.1") == .prerelease)
        #expect(SoakTagClass(tag: "1.0.0-rc.2") == .prerelease)
        #expect(SoakTagClass(tag: "not-a-version") == nil)
    }
}

@Suite("Soak release findings")
struct SoakFindingsTests {

    @Test("a sound, recent, matching soak raises nothing")
    func clean() {
        let report = ReleasePreflight.soak(result: result(), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(report.findings.isEmpty)
        #expect(report.notes.isEmpty)
    }

    @Test("a required tag with no result is soak-missing")
    func missing() {
        let report = ReleasePreflight.soak(result: nil, currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(report) == ["release.soak-missing"])
    }

    @Test("a patch tag with no result is advised, never blocked")
    func advised() {
        let report = ReleasePreflight.soak(result: nil, currentDigest: digest, tag: "v2.1.1", release: required, now: now)
        #expect(report.findings.isEmpty)
        #expect(report.notes.map(\.ruleId) == ["release.soak-advised"])
    }

    @Test("nothing is required by default: an empty requiredFor changes nothing")
    func defaultsToNothing() {
        let off = SoakRelease(requiredFor: [], minSeconds: 5400, maxAgeDays: 14, requireDrain: true, limits: .calibrated, waiver: nil)
        let report = ReleasePreflight.soak(result: nil, currentDigest: digest, tag: "v3.0.0", release: off, now: now)
        #expect(report.findings.isEmpty)
    }

    @Test("a soak of other source is stale")
    func stale() {
        let report = ReleasePreflight.soak(
            result: result(sourceDigest: String(repeating: "b", count: 64)), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(report) == ["release.soak-stale-source"])
    }

    @Test("a soak shorter than the floor is too short")
    func tooShort() {
        let short = samples(minutes: 60)
        let report = ReleasePreflight.soak(
            result: result(samples: short, durationSeconds: 3600), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(report).contains("release.soak-too-short"))
    }

    @Test("a soak that grew fails soak-grew and says by how much")
    func grew() {
        let ramp = samples(footprint: { 20 + 4 * $0 / 60 })
        let report = ReleasePreflight.soak(result: result(samples: ramp), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(report) == ["release.soak-grew"])
        #expect(report.findings.first?.message.contains("MB/h") == true)
    }

    @Test("a soak ended too long ago is old")
    func old() {
        let report = ReleasePreflight.soak(
            result: result(endedAt: now.addingTimeInterval(-15 * 86_400)), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(report) == ["release.soak-old"])
    }

    @Test("a sealed pass over samples that ramp is forged")
    func forged() {
        let ramp = samples(footprint: { 20 + 4 * $0 / 60 })
        let honest = SoakJudgement.judge(samples: samples(), architecture: "x86_64", limits: .calibrated)
        let report = ReleasePreflight.soak(
            result: result(samples: ramp, sealed: honest), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(report).contains("release.soak-verdict-forged"))
        #expect(ids(report).contains("release.soak-grew"))
    }

    @Test("no drain, or a failed drain, blocks only when a drain is required")
    func drain() {
        let none = ReleasePreflight.soak(result: result(drain: nil), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(none) == ["release.soak-no-drain"])
        let failed = ReleasePreflight.soak(
            result: result(drain: SoakDrain(exitCode: 1, seconds: 3)), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(failed) == ["release.soak-no-drain"])
        let relaxed = SoakRelease(requiredFor: [.major, .minor], minSeconds: 5400, maxAgeDays: 14, requireDrain: false,
                                  limits: .calibrated, waiver: nil)
        #expect(ReleasePreflight.soak(result: result(drain: nil), currentDigest: digest, tag: "v2.1.0", release: relaxed, now: now).findings.isEmpty)
    }

    @Test("a footprint series of whole megabytes is quantised")
    func quantised() {
        let whole = samples(footprint: { _ in 20 })
        let report = ReleasePreflight.soak(result: result(samples: whole), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(report) == ["release.soak-quantised"])
    }

    @Test("fewer samples than the duration and interval promise is sparse")
    func sparse() {
        let thin = samples().enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        let report = ReleasePreflight.soak(
            result: result(samples: thin), currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(ids(report).contains("release.soak-sparse"))
    }

    @Test("a result written by another schema version is refused as unreadable")
    func schema() {
        var r = result()
        r = SoakResult(
            schemaVersion: 99, package: r.package, sourceDigest: r.sourceDigest, startedAt: r.startedAt, endedAt: r.endedAt,
            durationSeconds: r.durationSeconds, host: r.host, toolchain: r.toolchain, intervalSeconds: r.intervalSeconds,
            architecture: r.architecture, samples: r.samples, drain: r.drain, reloaded: r.reloaded, sealed: r.sealed)
        #expect(ids(ReleasePreflight.soak(result: r, currentDigest: digest, tag: "v2.1.0", release: required, now: now))
            == ["release.soak-unreadable"])
    }

    @Test("an architecture the rule was not calibrated on is a note, not a finding")
    func uncalibrated() {
        let s = samples()
        let arm = SoakResult(
            schemaVersion: SoakResult.currentSchemaVersion, package: "Demo", sourceDigest: digest,
            startedAt: now.addingTimeInterval(-90_000), endedAt: now.addingTimeInterval(-86_400), durationSeconds: 6000,
            host: "Mac", toolchain: "Swift", intervalSeconds: 30, architecture: "arm64", samples: s,
            drain: SoakDrain(exitCode: 0, seconds: 3), reloaded: true,
            sealed: SoakJudgement.judge(samples: s, architecture: "arm64", limits: .calibrated))
        let report = ReleasePreflight.soak(result: arm, currentDigest: digest, tag: "v2.1.0", release: required, now: now)
        #expect(report.findings.isEmpty)
        #expect(report.notes.map(\.ruleId) == ["release.soak-uncalibrated"])
    }

    @Test("a waiver for this version silences the findings and says so; for another version it does nothing")
    func waiver() {
        let waiver = SoakWaiver(version: "2.1.0", reason: "docs only", date: "2026-12-01")
        let waived = SoakRelease(requiredFor: [.major, .minor], minSeconds: 5400, maxAgeDays: 14, requireDrain: true,
                                 limits: .calibrated, waiver: waiver)
        let report = ReleasePreflight.soak(result: nil, currentDigest: digest, tag: "v2.1.0", release: waived, now: now)
        #expect(report.findings.isEmpty)
        #expect(report.notes.map(\.ruleId) == ["release.soak-waived"])
        let other = ReleasePreflight.soak(result: nil, currentDigest: digest, tag: "v2.2.0", release: waived, now: now)
        #expect(ids(other) == ["release.soak-missing"])
    }

    @Test("a result round-trips through JSON unchanged")
    func codable() throws {
        let original = result()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(SoakResult.self, from: encoder.encode(original)) == original)
    }
}
