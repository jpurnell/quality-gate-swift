import Foundation
import Testing
@testable import ReleaseReadinessAuditor

/// The 54 fresh-start runs of the 2026-11 calibration campaign (Chromedome, x86_64), copied from SwiftSoakKit's
/// fixtures with the verdicts an independent numpy implementation of the rule produced. This package's answer governs
/// where the two disagree, because the gate recomputes from the file; they must not disagree on these.
@Suite("Soak judgement: the calibration fixtures")
struct SoakJudgementFixtureTests {

    private struct Expected: Decodable {
        let outcome: String
        let slope: Double?
        let drift: Int?
    }

    private static func fixture(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "SoakFixtures/\(name)", withExtension: ext), "missing fixture \(name)")
    }

    @Test("every campaign run reaches the recorded verdict, slope and descriptor drift")
    func everyRun() throws {
        let expected = try JSONDecoder().decode(
            [String: Expected].self, from: Data(contentsOf: Self.fixture("expected", "json")))
        #expect(expected.count == 54)
        for (name, want) in expected.sorted(by: { $0.key < $1.key }) {
            let text = try String(contentsOf: Self.fixture(name, "csv"), encoding: .utf8)
            let file = try SoakSamplesFile.parse(text)
            let got = SoakJudgement.judge(samples: file.samples, architecture: file.architecture, limits: .calibrated)
            switch got.verdict {
            case .pass: #expect(want.outcome == "pass", "\(name): got pass")
            case .fail: #expect(want.outcome == "fail", "\(name): got fail")
            case .inconclusive: #expect(want.outcome == "inconclusive", "\(name): got inconclusive")
            }
            if let slope = want.slope, let drift = want.drift {
                #expect(abs((got.slopeMBPerHour ?? .nan) - slope) < 1e-5, "\(name): slope")
                #expect(got.descriptorDrift == drift, "\(name): drift")
            }
            #expect(got.notes.isEmpty, "\(name): the fixtures declare x86_64")
        }
    }
}

private func run(
    minutes: Double = 100,
    footprint: (Double) -> Double = { _ in 20 },
    descriptors: (Double) -> Int = { _ in 12 }
) -> [SoakSample] {
    stride(from: 22.0, to: minutes * 60, by: 30).map {
        SoakSample(t: $0, footprintMB: footprint($0 / 60), descriptors: descriptors($0 / 60))
    }
}

@Suite("Soak judgement")
struct SoakJudgementTests {

    @Test("a flat run passes")
    func flat() {
        #expect(SoakJudgement.judge(samples: run(), architecture: "x86_64", limits: .calibrated).verdict == .pass)
    }

    @Test("growth past the limit fails, and the reason names the footprint")
    func leak() {
        let e = SoakJudgement.judge(samples: run(footprint: { 20 + 4 * $0 / 60 }), architecture: "x86_64", limits: .calibrated)
        guard case .fail(let reasons) = e.verdict else { Issue.record("expected fail, got \(e.verdict)"); return }
        #expect(reasons.contains { $0.contains("footprint") })
    }

    @Test("growth in the pre-warm period is not counted")
    func preWarm() {
        let e = SoakJudgement.judge(
            samples: run(footprint: { 20 + min($0, 30) * 20 / 30 }), architecture: "x86_64", limits: .calibrated)
        #expect(e.verdict == .pass)
    }

    @Test("a run too short for the window is inconclusive, never a pass")
    func tooShort() {
        let e = SoakJudgement.judge(samples: run(minutes: 60), architecture: "x86_64", limits: .calibrated)
        #expect(e.verdict == .inconclusive(reason: "the window (30 to 90 minutes) holds 60 of about 120 expected samples"))
        #expect(e.slopeMBPerHour == nil)
    }

    @Test("a descriptor leak fails on the lower envelope; one open connection does not")
    func descriptors() {
        let leak = SoakJudgement.judge(samples: run(descriptors: { 12 + Int($0 / 5) }), architecture: "x86_64", limits: .calibrated)
        guard case .fail(let reasons) = leak.verdict else { Issue.record("expected fail"); return }
        #expect(reasons.contains { $0.contains("descriptor") })

        var spiked = run()
        spiked[100] = SoakSample(t: spiked[100].t, footprintMB: 20, descriptors: 40)
        #expect(SoakJudgement.judge(samples: spiked, architecture: "x86_64", limits: .calibrated).verdict == .pass)
    }

    @Test("sample order does not matter")
    func unsorted() {
        let ramp = run(footprint: { 20 + 4 * $0 / 60 })
        #expect(
            SoakJudgement.judge(samples: ramp, architecture: "x86_64", limits: .calibrated)
                == SoakJudgement.judge(samples: ramp.reversed(), architecture: "x86_64", limits: .calibrated))
    }

    @Test("a host other than the calibrated one, or none recorded, is noted and the verdict stands")
    func architecture() {
        let other = SoakJudgement.judge(samples: run(), architecture: "arm64", limits: .calibrated)
        #expect(other.verdict == .pass)
        #expect(other.notes.contains { $0.contains("arm64") && $0.contains("x86_64") })
        #expect(SoakJudgement.judge(samples: run(), architecture: nil, limits: .calibrated).notes.contains { $0.contains("not recorded") })
    }

    @Test("a non-finite reading, or a limit that is not a number, is inconclusive rather than a figure or a trap")
    func nonFinite() {
        var bad = run()
        bad[150] = SoakSample(t: bad[150].t, footprintMB: .nan, descriptors: 12)
        #expect(SoakJudgement.judge(samples: bad, architecture: "x86_64", limits: .calibrated).verdict
            == .inconclusive(reason: "a reading is not a finite number"))
        let nanLimits = SoakLimits(preWarmSeconds: .nan, windowSeconds: 3600, slopeLimitMBPerHour: 2, descriptorDriftLimit: 8)
        #expect(SoakJudgement.judge(samples: run(), architecture: "x86_64", limits: nanLimits).verdict
            == .inconclusive(reason: "the limits contain a value that is not a usable number"))
    }
}

@Suite("Soak samples file")
struct SoakSamplesFileTests {

    @Test("columns are found by name, extra columns are ignored, the architecture comes from the first line")
    func parse() throws {
        let file = try SoakSamplesFile.parse("# architecture: x86_64\nt,footprintMB,descriptors,rssMB\n22.2,9.68,11,17.0\n")
        #expect(file.architecture == "x86_64")
        #expect(file.samples == [SoakSample(t: 22.2, footprintMB: 9.68, descriptors: 11)])
    }

    @Test("a missing column, a malformed row and an oversized file are errors, not crashes")
    func malformed() {
        #expect(throws: SoakSamplesFile.ParseError.missingColumn("descriptors")) { try SoakSamplesFile.parse("t,footprintMB\n1,2\n") }
        #expect(throws: SoakSamplesFile.ParseError.badRow(line: 3)) {
            try SoakSamplesFile.parse("t,footprintMB,descriptors\n1,2,3\n4,x,6\n")
        }
        let huge = "t,footprintMB,descriptors\n" + String(repeating: "1,1,1\n", count: SoakSamplesFile.maximumSamples + 1)
        #expect(throws: SoakSamplesFile.ParseError.tooManySamples) { try SoakSamplesFile.parse(huge) }
    }
}
