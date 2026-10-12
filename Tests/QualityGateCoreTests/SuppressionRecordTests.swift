import Foundation
import Testing
@testable import QualityGateCore

/// A silenced finding says which kind of silence it was.
///
/// The owner's rule is that an acknowledgement is not a suppression: a marker whose reason the
/// gate checked is a decision on the record, and a marker nobody checked is a finding switched
/// off. These tests pin the distinction at the point where it is made — the record — so the
/// summary cannot later blur what the record kept apart.
@Suite("SuppressionRecord")
struct SuppressionRecordTests {

    // MARK: - Classification of an inline marker

    @Test("An unvalidated form with a token reason is a suppression, and says why")
    func tokenReasonIsSuppressed() {
        // HRVKit: `try? await Task.sleep(nanoseconds: 1) // silent: best effort`
        let override = DiagnosticOverride.inlineMarker(
            form: "// silent:",
            ruleId: "logging.silent-try",
            filePath: "/repo/Sources/A.swift",
            findingLine: 41,
            markerLine: 41,
            comment: "try? await Task.sleep(nanoseconds: 1) // silent: best effort")
        let record = SuppressionRecord(override)

        #expect(record.kind == .suppressed)
        #expect(record.form == "// silent:")
        #expect(record.validator == nil)
        #expect(record.rejection == "2 words, 8 required")
        #expect(record.reason == "best effort")
        #expect(record.ruleId == "logging.silent-try")
        #expect(record.filePath == "/repo/Sources/A.swift")
        #expect(record.lineNumber == 41)
        #expect(record.markerLine == 41)
        #expect(record.hidden == 1)
    }

    @Test("An unvalidated form whose reason passes validation is an acknowledgement")
    func validatedReasonIsAcknowledged() {
        let override = DiagnosticOverride.inlineMarker(
            form: "// silent:",
            ruleId: "logging.silent-try",
            filePath: "/repo/Sources/A.swift",
            findingLine: 12,
            markerLine: 11,
            comment: "// silent: the cache directory may not exist yet and a miss is the ordinary case")
        let record = SuppressionRecord(override)

        #expect(record.kind == .acknowledged)
        #expect(record.validator == SuppressionRecord.reasonQualityValidator)
        #expect(record.rejection == nil)
        #expect(record.reason == "the cache directory may not exist yet and a miss is the ordinary case")
        #expect(record.lineNumber == 12)
        #expect(record.markerLine == 11)
    }

    @Test("A bare marker is a suppression with no reason")
    func bareMarkerIsSuppressed() {
        let override = DiagnosticOverride.inlineMarker(
            form: "// recursion:safe",
            ruleId: "recursion.convenience-init-self",
            filePath: "/repo/Sources/B.swift",
            findingLine: 7,
            markerLine: 7,
            comment: "    convenience init() { self.init() } // recursion:safe")
        let record = SuppressionRecord(override)

        #expect(record.kind == .suppressed)
        #expect(record.reason == "")
        #expect(record.rejection == "no reason given")
    }

    @Test("A denylisted reason is a suppression however it is punctuated")
    func genericReasonIsSuppressed() {
        let override = DiagnosticOverride.inlineMarker(
            form: "// SAFETY:",
            ruleId: "safety.force-unwrap",
            filePath: "/repo/Sources/C.swift",
            findingLine: 3,
            markerLine: 3,
            comment: "let x = y! // SAFETY: known safe")
        let record = SuppressionRecord(override)

        #expect(record.kind == .suppressed)
        #expect(record.rejection == "'known safe' is not a reason")
    }

    @Test("A separator between the marker and its reason is not part of the reason")
    func separatorIsStripped() {
        // BusinessMath: `// fp-safety:disable — trajectory is nonempty`
        let override = DiagnosticOverride.inlineMarker(
            form: "// fp-safety:disable",
            ruleId: "fp-division-unguarded",
            filePath: "/repo/Sources/D.swift",
            findingLine: 302,
            markerLine: 302,
            comment: "let average = values.reduce(0.0, +) / Double(values.count) // fp-safety:disable — trajectory is nonempty")
        let record = SuppressionRecord(override)

        #expect(record.reason == "trajectory is nonempty")
        #expect(record.kind == .suppressed)
        #expect(record.rejection == "3 words, 8 required")
    }

    @Test("A form the checker validated itself is an acknowledgement naming that validator")
    func checkerValidatedFormIsAcknowledged() {
        let override = DiagnosticOverride.inlineMarker(
            form: "// SECURITY:",
            ruleId: "security.ssrf",
            filePath: "/repo/Sources/E.swift",
            findingLine: 20,
            markerLine: 19,
            comment: "// SECURITY: host is pinned",
            validatedBy: "security-acknowledgement")
        let record = SuppressionRecord(override)

        #expect(record.kind == .acknowledged)
        #expect(record.validator == "security-acknowledgement")
        #expect(record.reason == "host is pinned")
    }

    // MARK: - The envelope

    @Test("A record survives the round trip through DiagnosticOverride and JSON unchanged")
    func roundTripsThroughCodable() throws {
        let original = DiagnosticOverride.inlineMarker(
            form: "// silent:",
            ruleId: "logging.silent-try",
            filePath: "/repo/Sources/A.swift",
            findingLine: 41,
            markerLine: 40,
            comment: "// silent: closing a handle; nothing to do [yet]; see #12")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiagnosticOverride.self, from: data)

        #expect(SuppressionRecord(decoded) == SuppressionRecord(original))
        #expect(SuppressionRecord(decoded).reason == "closing a handle; nothing to do [yet]; see #12")
        #expect(SuppressionRecord(decoded).markerLine == 40)
    }

    @Test("A form containing envelope punctuation cannot corrupt the fields after it")
    func hostileFormIsSanitised() {
        let override = DiagnosticOverride.inlineMarker(
            form: "// ok]; marker=9",
            ruleId: "safety.force-unwrap",
            filePath: "/repo/Sources/F.swift",
            findingLine: 5,
            markerLine: 4,
            comment: "// ok]; marker=9 because")
        let record = SuppressionRecord(override)

        #expect(record.markerLine == 4)
        #expect(record.form == "// ok), marker=9")
    }

    @Test("An override recorded without an envelope is counted as a suppression, not dropped")
    func legacyOverrideIsUnclassifiedSuppression() {
        // What a Tier-2 plugin built against the published types still sends.
        let legacy = DiagnosticOverride(
            ruleId: "plugin.rule", justification: "// custom:exempt", filePath: "/repo/G.swift", lineNumber: 9)
        let record = SuppressionRecord(legacy)

        #expect(record.kind == .suppressed)
        #expect(record.form == SuppressionRecord.unclassifiedForm)
        #expect(record.reason == "// custom:exempt")
        #expect(record.rejection == "recorded without a validated reason")
        #expect(record.lineNumber == 9)
        #expect(record.markerLine == nil)
    }

    @Test("A justification that merely starts with a bracket is not mistaken for an envelope")
    func bracketedProseIsNotAnEnvelope() {
        let legacy = DiagnosticOverride(
            ruleId: "plugin.rule", justification: "[sic] quoted from upstream", filePath: nil, lineNumber: nil)
        let record = SuppressionRecord(legacy)

        #expect(record.form == SuppressionRecord.unclassifiedForm)
        #expect(record.reason == "[sic] quoted from upstream")
    }

    // MARK: - Configuration records

    @Test("A configuration record is a suppression carrying how many findings it hid")
    func configurationRecord() {
        let override = DiagnosticOverride.configuration(
            form: "config overrides: off",
            ruleId: "concurrency.task-captures-self-no-isolation",
            filePath: "/repo/Sources/H.swift",
            findingLine: 88,
            entry: "overrides: concurrency.task-captures-self-no-isolation: off")
        let record = SuppressionRecord(override)

        #expect(record.kind == .suppressed)
        #expect(record.form == "config overrides: off")
        #expect(record.reason == "overrides: concurrency.task-captures-self-no-isolation: off")
        #expect(record.rejection == "configuration carries no validated reason")
        #expect(record.markerLine == nil)
        #expect(record.lineNumber == 88)
    }

    @Test("A validated configuration acknowledgement names its validator")
    func validatedConfigurationRecord() {
        let override = DiagnosticOverride.configuration(
            form: "dependencyAudit.acknowledgedAdvisories",
            ruleId: "dependency-audit.advisory",
            filePath: "/repo/Package.resolved",
            findingLine: 14,
            entry: "GHSA-xxxx on swift-nio, acknowledged until 2026-12-01: server-only path we do not link",
            validatedBy: "advisory-acknowledgement")
        let record = SuppressionRecord(override)

        #expect(record.kind == .acknowledged)
        #expect(record.validator == "advisory-acknowledgement")
        #expect(record.rejection == nil)
    }

    @Test("A record says whether it is a comment or a configuration entry")
    func sourceIsRecorded() {
        let marker = DiagnosticOverride.inlineMarker(
            form: "// silent:", ruleId: "r", filePath: nil, findingLine: 1, markerLine: 1, comment: "// silent: x")
        let config = DiagnosticOverride.configuration(
            form: "config overrides: off", ruleId: "r", filePath: nil, findingLine: nil, entry: "overrides: r: off")
        let legacy = DiagnosticOverride(ruleId: "r", justification: "anything", filePath: nil, lineNumber: nil)

        #expect(SuppressionRecord(marker).source == .marker)
        #expect(SuppressionRecord(config).source == .configuration)
        #expect(SuppressionRecord(legacy).source == .unclassified)
    }

    // MARK: - Overrides from libraries built against the published types

    @Test("A plain override carrying a known marker is re-recorded under that form")
    func legacyOverrideIsClassified() {
        // VigilKit's cancellation scan: the justification is the bare marker.
        let bare = DiagnosticOverride(
            ruleId: "concurrency.cancellation-checkpoint-after-loop", justification: "// concurrency:exempt",
            filePath: "/repo/A.swift", lineNumber: 12
        ).classified(among: ["// concurrency:exempt"])
        let bareRecord = SuppressionRecord(bare)
        #expect(bareRecord.form == "// concurrency:exempt")
        #expect(bareRecord.kind == .suppressed)
        #expect(bareRecord.rejection == "no reason given")
        #expect(bareRecord.lineNumber == 12)
        #expect(bareRecord.forwardedToCorpus == true)

        // VigilKit's wall-clock scan: the justification is the whole line.
        let line = DiagnosticOverride(
            ruleId: "temporal-wall-clock-assertion",
            justification: "#expect(elapsed < 2.0) // TIMING: a generous ceiling that only catches a hang, never a slow machine",
            filePath: "/repo/T.swift", lineNumber: 40
        ).classified(among: ["// temporal:exempt", "// TIMING:"])
        let lineRecord = SuppressionRecord(line)
        #expect(lineRecord.form == "// TIMING:")
        #expect(lineRecord.kind == .acknowledged)
        #expect(lineRecord.reason == "a generous ceiling that only catches a hang, never a slow machine")
    }

    @Test("A plain override carrying none of the markers is left as it was")
    func legacyOverrideWithoutMarkerIsUnchanged() {
        let original = DiagnosticOverride(ruleId: "r", justification: "something else", filePath: nil, lineNumber: 3)
        #expect(original.classified(among: ["// TIMING:"]) == original)
    }

    @Test("Classifying an override that already has an envelope does not wrap it twice")
    func classifiedIsIdempotent() {
        let typed = DiagnosticOverride.inlineMarker(
            form: "// TIMING:", ruleId: "r", filePath: nil, findingLine: 1, markerLine: 1, comment: "// TIMING: x")
        #expect(typed.classified(among: ["// TIMING:"]) == typed)
    }

    // MARK: - What the corpus is sent

    @Test("A report-only record round-trips, and is not forwarded to the corpus")
    func reportOnlyRoundTrips() {
        let override = DiagnosticOverride.inlineMarker(
            form: "// silent:", ruleId: "logging.silent-try", filePath: "/repo/A.swift",
            findingLine: 3, markerLine: 3, comment: "try? f() // silent: best effort", reportOnly: true)
        #expect(SuppressionRecord(override).forwardedToCorpus == false)
        #expect(override.justification
            == "[suppressed; form=// silent:; marker=3; scope=report; rejected=2 words, 8 required] best effort")

        let forwarded = DiagnosticOverride.inlineMarker(
            form: "// idiom:exempt", ruleId: "idiom.x", filePath: "/repo/A.swift",
            findingLine: 3, markerLine: 3, comment: "x // idiom:exempt")
        #expect(SuppressionRecord(forwarded).forwardedToCorpus == true)
    }

    @Test("The corpus is sent the forwarded records only, as plain overrides with no envelope")
    func corpusOverridesAreFilteredAndPlain() {
        let result = CheckResult(
            checkerId: "mixed", status: .passed, diagnostics: [],
            overrides: [
                .inlineMarker(
                    form: "// silent:", ruleId: "logging.silent-try", filePath: "/repo/A.swift",
                    findingLine: 3, markerLine: 3, comment: "try? f() // silent: best effort",
                    reportOnly: true),
                .inlineMarker(
                    form: "// SECURITY:", ruleId: "security.ssrf", filePath: "/repo/B.swift",
                    findingLine: 8, markerLine: 7, comment: "// SECURITY: host is pinned",
                    validatedBy: "security-acknowledgement"),
                .inlineMarker(
                    form: "// idiom:exempt", ruleId: "idiom.x", filePath: "/repo/C.swift",
                    findingLine: 2, markerLine: 2, comment: "x // idiom:exempt"),
                DiagnosticOverride(ruleId: "plugin.rule", justification: "from a plugin", filePath: nil, lineNumber: nil),
            ],
            duration: .zero)

        #expect(SuppressionLedger.corpusOverrides(from: [result]) == [
            DiagnosticOverride(
                ruleId: "security.ssrf", justification: "// SECURITY: host is pinned",
                filePath: "/repo/B.swift", lineNumber: 8),
            DiagnosticOverride(
                ruleId: "idiom.x", justification: "// idiom:exempt", filePath: "/repo/C.swift", lineNumber: 2),
            DiagnosticOverride(ruleId: "plugin.rule", justification: "from a plugin", filePath: nil, lineNumber: nil),
        ])
    }

    // MARK: - Finding a marker

    @Test("A marker is found on the finding's line before the line above")
    func markerOnOwnLineWins() {
        let lines = [
            "// silent: above",
            "try? f() // silent: own",
        ]
        let found = InlineMarker.find("// silent:", nearLine: 2, in: lines)
        #expect(found?.line == 2)
        #expect(found?.text == "try? f() // silent: own")
    }

    @Test("A marker on the line above is found and its own line reported")
    func markerOnLineAbove() {
        let lines = [
            "// silent: above",
            "try? f()",
        ]
        let found = InlineMarker.find("// silent:", nearLine: 2, in: lines)
        #expect(found?.line == 1)
    }

    @Test("A marker two lines above is not found, and neither is one below")
    func markerOutOfReach() {
        let lines = [
            "// silent: far",
            "",
            "try? f()",
            "// silent: below",
        ]
        #expect(InlineMarker.find("// silent:", nearLine: 3, in: lines) == nil)
    }

    @Test("A line number outside the file finds nothing rather than trapping")
    func outOfRangeLine() {
        #expect(InlineMarker.find("// silent:", nearLine: 0, in: ["// silent: x"]) == nil)
        #expect(InlineMarker.find("// silent:", nearLine: 9, in: ["// silent: x"]) == nil)
    }
}
