import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// The merge both roster generators share: membership is derived, everything else is the
/// author's and survives untouched.
@Suite("Roster merge")
struct RosterTests {

    @Test("A line's subject is the first word after the tick-box, backticks and all")
    func subject() {
        #expect(Roster.subject(of: "- [x] QualityGateCore — Protocol, models, reporters") == "QualityGateCore")
        #expect(Roster.subject(of: "- [ ] XcodeReporter — `--format xcode`") == "XcodeReporter")
        #expect(Roster.subject(of: "- `IJSSensor` — Telemetry capture") == "IJSSensor")
        #expect(Roster.subject(of: "- [x] ~~DiskCleaner~~ — moved to `clean`") == "DiskCleaner")
        #expect(Roster.subject(of: "") == nil)
        #expect(Roster.subject(of: "Not a list item at all") == nil)
    }

    @Test("A surviving entry is emitted byte-for-byte, tick-box and description included")
    func survivingEntriesArePreserved() {
        let body = """
        - [x] Alpha — the first one (200 tests)
        - [ ] Beta — <!-- needs a description -->
        """
        let merged = Roster.merge(
            body: body, members: ["Alpha", "Beta"],
            line: { "- [ ] \($0) — placeholder" })

        #expect(merged == body.lines)
    }

    @Test("A member with no line arrives unchecked, because nothing derives whether it is done")
    func newMembersArriveUnchecked() {
        let merged = Roster.merge(
            body: "- [x] Alpha — the first one", members: ["Alpha", "Gamma"],
            line: { "- [ ] \($0) — <!-- needs a description -->" })

        #expect(merged == [
            "- [x] Alpha — the first one",
            "- [ ] Gamma — <!-- needs a description -->",
        ])
    }

    @Test("A line for something that is no longer a member is dropped")
    func departedMembersAreDropped() {
        let merged = Roster.merge(
            body: """
            - [x] Alpha — the first one
            - [x] Removed — deleted last week
            """,
            members: ["Alpha"], line: { "- [ ] \($0)" })

        #expect(merged == ["- [x] Alpha — the first one"])
    }

    @Test("Existing order is kept; new members are appended in declaration order")
    func orderIsPreserved() {
        let merged = Roster.merge(
            body: """
            - [x] Gamma — third, but written first
            - [x] Alpha — first, but written second
            """,
            members: ["Alpha", "Beta", "Gamma", "Delta"], line: { "- [ ] \($0)" })

        #expect(merged == [
            "- [x] Gamma — third, but written first",
            "- [x] Alpha — first, but written second",
            "- [ ] Beta",
            "- [ ] Delta",
        ])
    }

    @Test("A struck entry survives even when it names nothing that exists any more")
    func struckEntriesSurviveTheirSubject() {
        // `CLAUDE.md`: strike through completed items rather than deleting them, and keep the
        // reasoning recorded at the time. A generator that dropped this line because no target
        // answers to `DiskCleaner` would destroy the one record of where the feature went —
        // which is §8.5's mistake, made by a machine instead of a person.
        let merged = Roster.merge(
            body: """
            - [x] Alpha — the first one
            - [x] ~~DiskCleaner~~ — became the `clean` subcommand, off the checker protocol
            """,
            members: ["Alpha"], line: { "- [ ] \($0)" })

        #expect(merged.count == 2)
        #expect(merged[1].contains("~~DiskCleaner~~"))
    }

    @Test("A struck entry does not re-add its subject as a new member either")
    func struckSubjectCountsAsPresent() {
        let merged = Roster.merge(
            body: "- [x] ~~Alpha~~ — folded into Beta",
            members: ["Alpha"], line: { "- [ ] \($0) — <!-- needs a description -->" })

        #expect(merged == ["- [x] ~~Alpha~~ — folded into Beta"])
    }

    @Test("A line that names nothing is not a roster entry and is dropped")
    func nonEntryLinesAreDropped() {
        // Prose inside a roster region is prose the region claims to have generated. The place
        // for it is above the opening delimiter, where nothing checks it.
        let merged = Roster.merge(
            body: """
            Some prose that wandered in.
            - [x] Alpha — the first one
            """,
            members: ["Alpha"], line: { "- [ ] \($0)" })

        #expect(merged == ["- [x] Alpha — the first one"])
    }

    @Test("A duplicated subject keeps the first line only, or the roster asserts it twice")
    func duplicateSubjectsCollapse() {
        let merged = Roster.merge(
            body: """
            - [x] Alpha — the first one
            - [ ] Alpha — a second opinion about the first one
            """,
            members: ["Alpha"], line: { "- [ ] \($0)" })

        #expect(merged == ["- [x] Alpha — the first one"])
    }

    @Test("Merging its own output changes nothing, or the document is permanently dirty")
    func idempotent() {
        let members = ["Alpha", "Beta"]
        let line: (String) -> String = { "- [ ] \($0) — <!-- needs a description -->" }
        let once = Roster.merge(body: "- [x] Alpha — the first one", members: members, line: line)
        let twice = Roster.merge(body: once.joined(separator: "\n"), members: members, line: line)

        #expect(once == twice)
    }
}
