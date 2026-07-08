import Testing
import Foundation
@testable import IJSSensor

@Suite("WorkLogFormatter")
struct WorkLogFormatterTests {
    // Fixed window [1_000_000, 2_000_000] on the Unix timeline — no parsing, no force-unwraps.
    private let windowStart = Date(timeIntervalSince1970: 1_000_000)
    private let windowEnd = Date(timeIntervalSince1970: 2_000_000)
    private let inWindow = Date(timeIntervalSince1970: 1_500_000)
    private let afterWindow = Date(timeIntervalSince1970: 3_000_000)

    private func event(
        date: Date,
        sha: String? = "abcdef1234567890",
        subjects: [String] = ["fix: something"],
        summary: String? = nil
    ) -> WorkEvent {
        WorkEvent(
            date: date,
            commitSHA: sha,
            commitSubjects: subjects,
            changelogDelta: nil,
            sessionSummary: summary
        )
    }

    @Test("In-window event appears with project, short SHA, and subject")
    func inWindowEventRendered() throws {
        let section = try #require(WorkLogFormatter.recentWorkSection(
            workLogsByProject: ["Alpha": [event(date: inWindow)]],
            windowStart: windowStart,
            windowEnd: windowEnd
        ))
        #expect(section.contains("Alpha"))
        #expect(section.contains("fix: something"))
        // SHA is truncated to 8 chars: the short form is present, the full is not.
        #expect(section.contains("@abcdef12"))
        #expect(!section.contains("abcdef1234567890"))
    }

    @Test("Out-of-window events are excluded; all-out yields nil")
    func outOfWindowExcluded() {
        let section = WorkLogFormatter.recentWorkSection(
            workLogsByProject: ["Alpha": [event(date: afterWindow, subjects: ["feat: later"])]],
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        #expect(section == nil)
    }

    @Test("Empty work-logs yield nil (section omitted)")
    func emptyYieldsNil() {
        #expect(WorkLogFormatter.recentWorkSection(
            workLogsByProject: [:],
            windowStart: windowStart,
            windowEnd: windowEnd
        ) == nil)
    }

    @Test("Session summary presence is flagged")
    func sessionSummaryFlagged() {
        let section = WorkLogFormatter.recentWorkSection(
            workLogsByProject: ["Alpha": [event(date: inWindow, summary: "did the work")]],
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        #expect(section?.contains("[session summary present]") == true)
    }

    @Test("Projects are sorted and mixed in/out-of-window events filter correctly")
    func sortingAndMixedFilter() throws {
        let section = try #require(WorkLogFormatter.recentWorkSection(
            workLogsByProject: [
                "Zeta": [event(date: inWindow, subjects: ["z work"])],
                "Alpha": [
                    event(date: inWindow, subjects: ["a work"]),
                    event(date: afterWindow, subjects: ["a later"])
                ]
            ],
            windowStart: windowStart,
            windowEnd: windowEnd
        ))
        // Alpha sorts before Zeta.
        let alphaIdx = try #require(section.range(of: "Alpha")).lowerBound
        let zetaIdx = try #require(section.range(of: "Zeta")).lowerBound
        #expect(alphaIdx < zetaIdx)
        // The out-of-window Alpha event is excluded; the in-window one is present.
        #expect(!section.contains("a later"))
        #expect(section.contains("a work"))
    }
}
