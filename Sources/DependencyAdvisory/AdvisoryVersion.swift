import Foundation

/// A version as SwiftPM tags and OSV ranges write one, ordered by SemVer 2.0 precedence.
///
/// ## Why not the first three dot-separated integers
///
/// GHSA-q36x-r5x4-h4q6 is fixed in `1.20` — range type `ECOSYSTEM`, no patch component. A
/// matcher that requires three components fails to parse that bound, never closes the range,
/// and reports a 2022 advisory against a 2026 pin: twelve repositories' worth, in the
/// measurement that preceded this checker. So one- and two-component versions are padded with
/// zeros, and anything that still is not a version is **not a version** — the initialiser fails,
/// and the caller reports the range as unevaluable rather than treating it as open.
struct AdvisoryVersion: Sendable, Equatable, Comparable {

    /// Major, minor, patch.
    let core: [UInt64]

    /// The dot-separated pre-release identifiers; empty for a release.
    let preRelease: [String]

    /// Parses `text`, or fails when it is not a version.
    ///
    /// Accepted: an optional leading `v`, one to three numeric components, an optional
    /// `-pre.release` suffix, and optional `+build` metadata, which carries no precedence and
    /// is dropped.
    init?(_ text: String) {
        var body = Substring(text)
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        if let plus = body.firstIndex(of: "+") { body = body[..<plus] }

        var preRelease: [String] = []
        if let dash = body.firstIndex(of: "-") {
            let suffix = body[body.index(after: dash)...]
            let identifiers = suffix.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !suffix.isEmpty, identifiers.allSatisfy(Self.isIdentifier) else { return nil }
            preRelease = identifiers
            body = body[..<dash]
        }

        let components = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var core: [UInt64] = []
        for component in components {
            guard !component.isEmpty, component.allSatisfy(\.isASCIIDigit), let value = UInt64(component) else {
                return nil
            }
            core.append(value)
        }
        while core.count < 3 { core.append(0) }

        self.core = core
        self.preRelease = preRelease
    }

    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit || $0 == "-" }
    }

    /// SemVer precedence: the core numerically, then a pre-release before its release, then the
    /// pre-release identifiers pairwise.
    static func < (lhs: AdvisoryVersion, rhs: AdvisoryVersion) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        if lhs.preRelease.isEmpty || rhs.preRelease.isEmpty {
            // A release has no identifiers and follows every pre-release of the same core.
            return !lhs.preRelease.isEmpty && rhs.preRelease.isEmpty
        }
        for (left, right) in zip(lhs.preRelease, rhs.preRelease) where left != right {
            return identifier(left, precedes: right)
        }
        return lhs.preRelease.count < rhs.preRelease.count
    }

    /// Numeric identifiers compare numerically and precede alphanumeric ones, which compare in
    /// ASCII order.
    private static func identifier(_ left: String, precedes right: String) -> Bool {
        switch (UInt64(left), UInt64(right)) {
        case (let leftNumber?, let rightNumber?): return leftNumber < rightNumber
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}

/// A calendar date written `YYYY-MM-DD`, ordered and countable without a formatter or a clock.
///
/// The snapshot's `fetched` and an acknowledgement's `until` are compared to each other, and the
/// snapshot's age is counted in days. Neither needs a time zone, and a `DateFormatter` would
/// bring one in along with a locale; this is arithmetic on three integers.
struct AdvisoryDate: Sendable, Equatable, Comparable {

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    let dayNumber: Int

    /// The date as written.
    let text: String

    /// Parses `YYYY-MM-DD`, failing on any other shape and on a day the month does not have.
    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year)
        else { return nil }
        self.text = text
        self.dayNumber = Self.dayNumber(year: year, month: month, day: day)
    }

    /// The UTC calendar date `instant` falls on.
    init(utcDateOf instant: Date) {
        let seconds = instant.timeIntervalSince1970
        let days = seconds.isFinite ? Int((seconds / 86_400).rounded(.down)) : 0
        self.dayNumber = days
        self.text = Self.text(forDayNumber: days)
    }

    static func < (lhs: AdvisoryDate, rhs: AdvisoryDate) -> Bool { lhs.dayNumber < rhs.dayNumber }

    static func == (lhs: AdvisoryDate, rhs: AdvisoryDate) -> Bool { lhs.dayNumber == rhs.dayNumber }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from the civil date to the epoch — Howard Hinnant's `days_from_civil`.
    private static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The civil date for a day number — the inverse, `civil_from_days`.
    private static func text(forDayNumber days: Int) -> String {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return "\(padded(year, to: 4))-\(padded(month, to: 2))-\(padded(day, to: 2))"
    }

    private static func padded(_ value: Int, to width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
