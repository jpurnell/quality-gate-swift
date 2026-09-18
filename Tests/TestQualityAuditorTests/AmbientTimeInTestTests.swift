import XCTest
import TestQualityAuditor
import QualityGateCore

/// `ambient-calendar-in-test` — a test whose date arithmetic depends on where it runs.
///
/// The rule covers `Calendar.current` and `Calendar(identifier:)` and nothing else. `Date()`
/// was in the first draft and was dropped: telling a *timestamp* reading from a *calendar
/// date* reading needs to follow the value through bindings and helpers, which a
/// `SyntaxVisitor` cannot do, and getting it wrong would have flagged the correct
/// bracketing tests while missing every reading laundered through a helper. The boundary
/// that survives is stated in `testLeavesTimestampReadingsToHardcodedDate`: a timestamp
/// wants `Date()`, a calendar date wants a fixed calendar.
final class AmbientTimeInTestTests: XCTestCase {

    private let auditor = TestQualityAuditor()
    private let ruleId = "ambient-calendar-in-test"

    private func result(_ source: String) async throws -> CheckResult {
        try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: Configuration())
    }

    private func diagnostics(_ source: String) async throws -> [Diagnostic] {
        try await result(source).diagnostics.filter { $0.ruleId == ruleId }
    }

    // MARK: - Must flag

    func testFlagsCalendarCurrent() async throws {
        // `BondPricingTests.swift@2251c71a:31`.
        let source = """
        import Testing

        @Test func accruedInterest() {
            let calendar = Calendar.current
            #expect(calendar.component(.year, from: settlement) == 2024)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lineNumber, 4)
        XCTAssertEqual(
            found.first?.severity, .error,
            "promoted 2026-09-16, after one release at warning took five repositories to zero")
    }

    func testFlagsCalendarIdentifierInitialiser() async throws {
        // It looks fixed — the calendar *system* is pinned — and it is not: the initialiser
        // takes no time zone, so the value carries `TimeZone.current`, and every component
        // it computes still depends on where the test runs.
        let source = """
        import Testing

        @Test func fiscalYear() {
            let calendar = Calendar(identifier: .gregorian)
            #expect(calendar.component(.month, from: yearEnd) == 9)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1)
    }

    func testFlagsReadingOutsideATestFunction() async throws {
        // `BondPricingTests` reads the calendar as a suite-level property, so a rule scoped
        // to `@Test` bodies would have missed the site the proposal names.
        let source = """
        import Testing

        struct BondPricingTests {
            let calendar = Calendar.current

            @Test func accruedInterest() {
                #expect(calendar.component(.year, from: settlement) == 2024)
            }
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lineNumber, 4)
    }

    func testFlagsEachReadingSeparately() async throws {
        let source = """
        import Testing

        @Test func twoReadings() {
            let a = Calendar.current
            let b = Calendar(identifier: .iso8601)
            #expect(a.component(.year, from: d) == b.component(.year, from: d))
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 2)
    }

    // MARK: - Must not flag

    func testIgnoresAFixedCalendarFixture() async throws {
        // The shape the diagnostic asks for: a named fixture that pins both the calendar
        // system and the time zone, defined once and shared.
        let source = """
        import Testing

        @Test func fiscalYear() {
            let calendar = gregorianUTC
            #expect(calendar.component(.month, from: yearEnd) == 9)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty)
    }

    func testIgnoresACalendarWhoseZoneIsPinnedOnTheFollowingLine() async throws {
        // Nine of the twenty-three sites across four consuming repositories are this, and
        // all nine are correct: `Calendar(identifier:)` pins the calendar *system*, and the
        // statement after it pins the only ambient part left. Flagging them taught people to
        // suppress the rule, which is the failure this rule cannot afford.
        let source = """
        import Testing

        @Test func dayCount() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
            #expect(calendar.component(.year, from: settlement) == 2024)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty, "system pinned by the initialiser, zone pinned by the next line")
    }

    func testIgnoresACalendarWhoseZoneIsPinnedFromGMT() async throws {
        let source = """
        import Testing

        @Test func dayCount() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            #expect(calendar.component(.year, from: settlement) == 2024)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty)
    }

    func testIgnoresACalendarPinnedBySiblingArgument() async throws {
        // SwiftZIP's `DOSTimeTests` and `ZIPWriterTests`, verbatim in shape. Both halves are
        // fixed in one expression, so the calendar never exists as a value whose zone is unset —
        // the cleanest form there is, and the first version of this carve-out flagged all eleven
        // sites because it only looked for a *later statement* assigning `.timeZone`. The rule
        // was at `error`, so it blocked that repository on its best-written tests.
        let source = """
        import Testing

        @Test func knownDateEncoding() throws {
            let components = DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(identifier: "UTC"),
                year: 2026, month: 6, day: 2,
                hour: 14, minute: 30, second: 0
            )
            let date = try #require(components.date)
            #expect(DOSTime.encode(date).0 == 0x7400)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty, "the zone is pinned in the same call that names the calendar")
    }

    func testStillFlagsASiblingArgumentWithNoZone() async throws {
        let source = """
        import Testing

        @Test func knownDateEncoding() throws {
            let components = DateComponents(
                calendar: Calendar(identifier: .gregorian),
                year: 2026, month: 6, day: 2
            )
            #expect(components.date != nil)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1, "no timeZone: argument means the zone is still ambient")
    }

    func testIgnoresACalendarWhoseZoneIsPinnedInsideABranch() async throws {
        // `DayCountTimeZoneTests.swift:55`. The pin is real; it is inside an `if let` because
        // `TimeZone(secondsFromGMT:)` is failable and the author would not force-unwrap it.
        // Reading only the next sibling statement would call this ambient and be wrong.
        let source = """
        import Testing

        @Test func dayCount() {
            var utc = Calendar(identifier: .gregorian)
            if let zone = TimeZone(secondsFromGMT: 0) { utc.timeZone = zone }
            #expect(utc.component(.year, from: settlement) == 2024)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty, "a conditional pin is still evidence the zone was considered")
    }

    func testIgnoresACalendarPinnedThroughDateComponents() async throws {
        // `TVMReferenceTests.swift:75`. The calendar is never bound to a name of its own —
        // it goes straight into a `DateComponents`, and the zone is pinned on that. The
        // question the rule is asking is the same one: was the zone decided?
        let source = """
        import Testing

        @Test func presentValue() {
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.timeZone = TimeZone(identifier: "UTC")
            #expect(components.date != nil)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty)
    }

    func testStillFlagsACalendarPutIntoComponentsWithNoZone() async throws {
        let source = """
        import Testing

        @Test func presentValue() {
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            #expect(components.date != nil)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1, "putting it somewhere is not deciding the zone")
    }

    func testStillFlagsCalendarCurrentWhenOnlyTheZoneIsPinned() async throws {
        // `Calendar.current` is not half-fixed by a time zone. The calendar *system* is still
        // the runner's, so a Japanese or Buddhist locale returns a different year for the
        // same instant. The carve-out is for the initialiser, which pins the system, and it
        // does not extend here.
        let source = """
        import Testing

        @Test func dayCount() {
            var calendar = Calendar.current
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            #expect(calendar.component(.year, from: settlement) == 2024)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1, "pinning the zone does not pin the calendar system")
    }

    func testStillFlagsACalendarThatPinsAnotherCalendarsZone() async throws {
        let source = """
        import Testing

        @Test func dayCount() {
            var pinned = Calendar(identifier: .iso8601)
            var drifting = Calendar(identifier: .gregorian)
            pinned.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            #expect(pinned.component(.year, from: d) == drifting.component(.year, from: d))
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1, "the assignment names one binding, and spares only it")
    }

    func testIgnoresAnUnrelatedCurrentReading() async throws {
        // The rule claims `Calendar` only. `TimeZone.current` and `Locale.current` are
        // ambient too, and are deliberately out of scope: the corpus evidence is about
        // calendar arithmetic, and a rule should claim the territory it measured.
        let source = """
        import Testing

        @Test func zoneName() {
            #expect(TimeZone.current.identifier.isEmpty == false)
            #expect(Locale.current.identifier.isEmpty == false)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty)
    }

    func testLeavesTimestampReadingsToHardcodedDate() async throws {
        // A timestamp wants `Date()`; a calendar date wants a fixed calendar.
        // `hardcoded-date` owns the first — its suggested fix is literally "Use Date()" —
        // and this rule owns the second. Neither mentions the other's territory, and a rule
        // that flagged `Date()` here would have pulled against `hardcoded-date` on one line.
        let source = """
        import Testing

        @Test func recency() {
            let stamp = Date()
            #expect(stamp.timeIntervalSinceNow < 1.0)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty, "Date() was dropped from this rule and stays dropped")
    }

    func testIgnoresACalendarNamedInAStringLiteral() async throws {
        let source = """
        import Testing

        @Test func reportsTheRule() {
            #expect(diagnostic.message.contains("Calendar.current"))
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Suppression

    func testLineMarkerSuppressesOneSiteAndIsRecorded() async throws {
        let source = """
        import Testing

        @Test func usesTheRunnersCalendar() {
            // TEST-QUALITY: ambient-calendar-in-test — the subject is what a user's own calendar yields
            let calendar = Calendar.current
            #expect(calendar.component(.year, from: settlement) >= 2024)
        }
        """

        let outcome = try await result(source)
        XCTAssertTrue(outcome.diagnostics.filter { $0.ruleId == ruleId }.isEmpty)
        XCTAssertEqual(outcome.overrides.filter { $0.ruleId == ruleId }.count, 1)
    }

    func testFileMarkerSuppressesEverySiteInTheFile() async throws {
        // A suite whose *subject* is zone behaviour reads the ambient calendar on purpose,
        // in every test. Repeating a line marker forty times is the noise that gets a rule
        // switched off, so the marker can be stated once for the file — still naming the
        // rule, still recorded as an override per site, so the count stays visible.
        let source = """
        import Testing

        // TEST-QUALITY-FILE: ambient-calendar-in-test — this suite's subject is time-zone behaviour

        @Test func componentsInTheRunnersZone() {
            let calendar = Calendar.current
            #expect(calendar.component(.year, from: d) >= 2024)
        }

        @Test func iso8601InTheRunnersZone() {
            let calendar = Calendar(identifier: .iso8601)
            #expect(calendar.component(.year, from: d) >= 2024)
        }
        """

        let outcome = try await result(source)
        XCTAssertTrue(
            outcome.diagnostics.filter { $0.ruleId == ruleId }.isEmpty,
            "one marker covers the file")
        XCTAssertEqual(
            outcome.overrides.filter { $0.ruleId == ruleId }.count, 2,
            "and every suppressed site is still counted")
    }

    func testFileMarkerSuppressesOnlyTheRuleItNames() async throws {
        let source = """
        import Testing

        // TEST-QUALITY-FILE: ambient-calendar-in-test — this suite's subject is time-zone behaviour

        @Test func componentsInTheRunnersZone() {
            let calendar = Calendar.current
            #expect(abs((counts["a"] ?? 0) - 3.0) < 1e-6)
            #expect(calendar.component(.year, from: d) >= 2024)
        }
        """

        let outcome = try await result(source)
        XCTAssertTrue(outcome.diagnostics.filter { $0.ruleId == ruleId }.isEmpty)
        XCTAssertEqual(
            outcome.diagnostics.filter { $0.ruleId == "coalesced-assertion" }.count, 1,
            "a file marker is scoped to its named rule, exactly as a line marker is")
    }

    func testBlanketMarkerDoesNotSuppressIt() async throws {
        let source = """
        import Testing

        @Test func usesTheRunnersCalendar() {
            let calendar = Calendar.current // TEST-QUALITY: intentional
            #expect(calendar.component(.year, from: settlement) >= 2024)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1)
    }

    // MARK: - Idempotence

    func testTwoRunsReportTheSameDiagnostics() async throws {
        let source = """
        import Testing

        @Test func twoReadings() {
            let a = Calendar.current
            let b = Calendar(identifier: .iso8601)
            #expect(a.component(.year, from: d) == b.component(.year, from: d))
        }
        """

        let first = try await diagnostics(source)
        let second = try await diagnostics(source)
        XCTAssertEqual(first.map(\.lineNumber), second.map(\.lineNumber))
        XCTAssertEqual(first.map(\.message), second.map(\.message))
    }
}
