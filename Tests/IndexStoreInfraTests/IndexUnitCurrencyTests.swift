import Foundation
import Testing
@testable import IndexStoreInfra

/// Which of a store's units describe the source as it is now.
///
/// A store's freshness was one comparison — newest unit against newest source — and that
/// comparison is true of a store in which most units are months old. These tests pin the
/// decision made about each unit on its own, as a function of three dates, so that none of it
/// depends on building anything.
@Suite("Index unit currency")
struct IndexUnitCurrencyTests {

    private static let august = Date(timeIntervalSince1970: 1_756_300_000)
    private static let yesterday = Date(timeIntervalSince1970: 1_759_600_000)
    private static let today = Date(timeIntervalSince1970: 1_759_700_000)

    // MARK: - One unit

    @Test("a unit written after its source was last edited is current")
    func unitNewerThanSourceIsCurrent() {
        let verdict = IndexUnitCurrency.verdict(
            unitDate: Self.today, sourceDate: Self.yesterday, newestSiblingDate: Self.today)
        #expect(verdict == .current)
    }

    @Test("a unit whose source was edited after it was written is stale")
    func unitOlderThanSourceIsStale() {
        let verdict = IndexUnitCurrency.verdict(
            unitDate: Self.august, sourceDate: Self.yesterday, newestSiblingDate: Self.august)
        #expect(verdict == .stale)
    }

    @Test("a unit whose source no longer exists is orphaned")
    func unitWithoutSourceIsOrphaned() {
        let verdict = IndexUnitCurrency.verdict(
            unitDate: Self.today, sourceDate: nil, newestSiblingDate: Self.today)
        #expect(verdict == .orphaned)
    }

    @Test("an older unit beside a newer one for the same compilation is superseded")
    func olderSiblingIsSuperseded() {
        // The source predates both, so neither is stale: the older is simply not the latest.
        let verdict = IndexUnitCurrency.verdict(
            unitDate: Self.yesterday, sourceDate: Self.august, newestSiblingDate: Self.today)
        #expect(verdict == .superseded)
    }

    /// The stronger statement wins. A unit that predates its source is wrong about the file
    /// whether or not something newer exists, and "superseded" would undersell that.
    @Test("a unit that is both stale and superseded is reported as stale")
    func staleOutranksSuperseded() {
        let verdict = IndexUnitCurrency.verdict(
            unitDate: Self.august, sourceDate: Self.yesterday, newestSiblingDate: Self.today)
        #expect(verdict == .stale)
    }

    /// A build writes the unit after reading the source, so equality is the boundary of
    /// "written after", not a tie to break towards distrust.
    @Test("a unit dated exactly as its source is current")
    func equalDatesAreCurrent() {
        let verdict = IndexUnitCurrency.verdict(
            unitDate: Self.today, sourceDate: Self.today, newestSiblingDate: Self.today)
        #expect(verdict == .current)
    }

    // MARK: - Platform identity

    @Test("deployment versions and the macosx spelling do not make a different platform")
    func platformIgnoresVersion() {
        #expect(IndexUnitCurrency.platform(ofTarget: "arm64-apple-macos12.0") == "arm64-macos")
        #expect(IndexUnitCurrency.platform(ofTarget: "arm64-apple-macosx12.0.0") == "arm64-macos")
        #expect(IndexUnitCurrency.platform(ofTarget: "arm64-apple-macos14.0") == "arm64-macos")
    }

    @Test("another operating system, architecture or environment is a different platform")
    func platformDistinguishesOSArchAndEnvironment() {
        #expect(IndexUnitCurrency.platform(ofTarget: "arm64-apple-ios17.0") == "arm64-ios")
        #expect(IndexUnitCurrency.platform(ofTarget: "arm64-apple-ios17.0-simulator") == "arm64-ios-simulator")
        #expect(IndexUnitCurrency.platform(ofTarget: "x86_64-apple-macos14.0") == "x86_64-macos")
        #expect(IndexUnitCurrency.platform(ofTarget: "x86_64-unknown-linux-gnu") == "x86_64-linux-gnu")
    }

    // MARK: - A whole store

    private func unit(
        _ name: String, _ date: Date, main: String,
        out: String? = nil, module: String = "CLI", target: String = "arm64-apple-macos14.0"
    ) -> IndexUnitRecord {
        IndexUnitRecord(
            name: name, modified: date, mainFile: main,
            outputFile: out ?? "/Pkg.build/Debug/\(name)", moduleName: module, target: target)
    }

    /// The Ignite store in miniature: a testable-variant unit from August beside today's.
    @Test("a census keeps the current unit and counts the stale one beside it")
    func censusSeparatesStaleFromCurrent() {
        let units = [
            unit("QRCodeError.o-STALE", Self.august, main: "/pkg/QRCodeError.swift",
                 out: "/Pkg.build/Debug/CLI-testable-t.build/QRCodeError.o"),
            unit("QRCodeError.o-FRESH", Self.today, main: "/pkg/QRCodeError.swift",
                 out: "/Pkg.build/Debug/CLI-p.build/QRCodeError.o"),
        ]
        let census = IndexUnitCurrency.census(units: units) { _ in Self.yesterday }

        #expect(census.currentOutputPaths == ["/Pkg.build/Debug/CLI-p.build/QRCodeError.o"])
        #expect(census.examined == 2)
        #expect(census.stale == 1)
        #expect(census.superseded == 0)
        #expect(census.orphaned == 0)
        #expect(census.ignored == 1)
        // The file is still described — by the fresh unit — so nothing is missing from the index.
        #expect(census.sourcesWithoutCurrentUnit.isEmpty)
    }

    @Test("a source whose every unit predates its last edit is reported as undescribed")
    func censusReportsSourcesWithNoCurrentUnit() {
        let units = [
            unit("A.o-1", Self.august, main: "/pkg/A.swift"),
            unit("B.o-1", Self.today, main: "/pkg/B.swift"),
        ]
        let census = IndexUnitCurrency.census(units: units) { path in
            path == "/pkg/A.swift" ? Self.yesterday : Self.august
        }

        #expect(census.currentOutputPaths == ["/Pkg.build/Debug/B.o-1"])
        #expect(census.stale == 1)
        #expect(census.sourcesWithoutCurrentUnit == ["/pkg/A.swift"])
    }

    /// A deleted file is not a hole in the index. Nothing can be anchored to it and nothing in
    /// the current source is left undescribed by ignoring it.
    @Test("an orphaned unit is ignored without reporting its source as undescribed")
    func orphanIsNotAnUndescribedSource() {
        let units = [unit("Gone.o-1", Self.today, main: "/pkg/Gone.swift")]
        let census = IndexUnitCurrency.census(units: units) { _ in nil }

        #expect(census.currentOutputPaths.isEmpty)
        #expect(census.orphaned == 1)
        #expect(census.sourcesWithoutCurrentUnit.isEmpty)
    }

    @Test("the older of two units for one compilation is superseded when the source is unchanged")
    func censusSupersedesTheOlderVariant() {
        let units = [
            unit("main.o-OLD", Self.yesterday, main: "/pkg/main.swift", out: "/b/CLI-testable-t.build/main.o"),
            unit("main.o-NEW", Self.today, main: "/pkg/main.swift", out: "/b/CLI-p.build/main.o"),
        ]
        let census = IndexUnitCurrency.census(units: units) { _ in Self.august }

        #expect(census.currentOutputPaths == ["/b/CLI-p.build/main.o"])
        #expect(census.superseded == 1)
        #expect(census.stale == 0)
    }

    /// The rule that keeps the fix from inventing findings. A file built for two platforms has
    /// two units that are both right, and each sees references the other's `#if` hides. Dropping
    /// the older would report everything only the older platform calls as unreachable.
    @Test("units for different platforms of one source do not supersede each other")
    func differentPlatformsAreSiblingsNotSuccessors() {
        let units = [
            unit("View.o-IOS", Self.yesterday, main: "/app/View.swift",
                 out: "/b/ios/View.o", module: "App", target: "arm64-apple-ios17.0-simulator"),
            unit("View.o-MAC", Self.today, main: "/app/View.swift",
                 out: "/b/mac/View.o", module: "App", target: "arm64-apple-macos14.0"),
        ]
        let census = IndexUnitCurrency.census(units: units) { _ in Self.august }

        #expect(census.currentOutputPaths.sorted() == ["/b/ios/View.o", "/b/mac/View.o"])
        #expect(census.superseded == 0)
    }

    @Test("one source compiled into two modules keeps a unit for each")
    func differentModulesAreSiblingsNotSuccessors() {
        let units = [
            unit("Shared.o-A", Self.yesterday, main: "/pkg/Shared.swift", out: "/b/A/Shared.o", module: "A"),
            unit("Shared.o-B", Self.today, main: "/pkg/Shared.swift", out: "/b/B/Shared.o", module: "B"),
        ]
        let census = IndexUnitCurrency.census(units: units) { _ in Self.august }

        #expect(census.currentOutputPaths.sorted() == ["/b/A/Shared.o", "/b/B/Shared.o"])
        #expect(census.superseded == 0)
    }

    /// The same compilation recorded by an older toolchain spells its triple differently. That
    /// is the accumulation the fix exists for, not a second platform.
    @Test("a unit from an older toolchain's spelling of the same platform is superseded")
    func olderTripleSpellingIsTheSamePlatform() {
        let units = [
            unit("X.o-OLD", Self.yesterday, main: "/pkg/X.swift", out: "/b/old/X.o", target: "arm64-apple-macosx12.0.0"),
            unit("X.o-NEW", Self.today, main: "/pkg/X.swift", out: "/b/new/X.o", target: "arm64-apple-macos12.0"),
        ]
        let census = IndexUnitCurrency.census(units: units) { _ in Self.august }

        #expect(census.currentOutputPaths == ["/b/new/X.o"])
        #expect(census.superseded == 1)
    }

    /// Module and precompiled-header units have no main file. They are reached through the
    /// source units that depend on them, so they are neither judged nor counted here.
    @Test("a unit with no main file is left to the units that depend on it")
    func unitsWithoutAMainFileAreNotExamined() {
        let units = [
            unit("Swift.swiftmodule-1", Self.august, main: ""),
            unit("A.o-1", Self.today, main: "/pkg/A.swift"),
        ]
        let census = IndexUnitCurrency.census(units: units) { _ in Self.yesterday }

        #expect(census.examined == 1)
        #expect(census.currentOutputPaths == ["/Pkg.build/Debug/A.o-1"])
    }

    // MARK: - What the run says

    @Test("the freshness note counts what was ignored, by reason")
    func noteCountsIgnoredUnits() {
        let freshness = IndexFreshness(
            newestSource: Self.yesterday, newestIndexUnit: Self.today, unitCount: 1_716)
        let census = IndexUnitCensus(
            currentOutputPaths: Array(repeating: "/b/x.o", count: 1_254),
            examined: 1_264, stale: 7, superseded: 2, orphaned: 1, sourcesWithoutCurrentUnit: [])

        let note = freshness.coverageNote(checkerId: "unreachable", census: census)

        #expect(note.ruleId == "unreachable.index.age")
        #expect(note.severity == .note)
        #expect(note.message.contains("1716 units"))
        #expect(note.message.contains("10 ignored (7 stale, 2 superseded, 1 orphaned)"))
    }

    @Test("a store with nothing to ignore says so rather than saying nothing")
    func noteStatesZeroIgnored() {
        let freshness = IndexFreshness(
            newestSource: Self.yesterday, newestIndexUnit: Self.today, unitCount: 57)
        let census = IndexUnitCensus(
            currentOutputPaths: ["/b/x.o"], examined: 8, stale: 0, superseded: 0, orphaned: 0,
            sourcesWithoutCurrentUnit: [])

        let note = freshness.coverageNote(checkerId: "unreachable", census: census)

        #expect(note.message.contains("0 ignored"))
    }

    /// A unit census can fail — the reader is a second library, loaded separately. The note
    /// must not then read as though every unit had been checked.
    @Test("a run that could not examine units individually says that")
    func noteAdmitsAnUnexaminedStore() {
        let freshness = IndexFreshness(
            newestSource: Self.yesterday, newestIndexUnit: Self.today, unitCount: 57)

        let note = freshness.coverageNote(checkerId: "unreachable", census: nil)

        #expect(note.message.contains("units were not examined individually"))
    }

    @Test("sources the index no longer describes raise a barrier that names them")
    func undescribedSourcesRaiseABarrier() {
        let census = IndexUnitCensus(
            currentOutputPaths: [], examined: 3, stale: 3, superseded: 0, orphaned: 0,
            sourcesWithoutCurrentUnit: ["/pkg/Tests/ATests.swift", "/pkg/Tests/BTests.swift"])

        let barrier = census.undescribedSourcesBarrier(
            checkerId: "unreachable", subject: "reachability",
            storeURL: URL(fileURLWithPath: "/pkg/.build/out"),
            sources: ["/pkg/Tests/ATests.swift", "/pkg/Tests/BTests.swift"])

        #expect(barrier.severity == .error)
        #expect(barrier.ruleId == "unreachable.index.stale-barrier")
        #expect(barrier.message.contains("2 source files"))
        #expect(barrier.message.contains("ATests.swift"))
        #expect(barrier.message.contains("reachability"))
        #expect(barrier.suggestedFix?.contains("swift build --build-tests") == true)
    }
}

/// How a unit's main file is turned into a path that can be dated.
@Suite("Index unit reader: main file path")
struct IndexUnitReaderPathTests {

    @Test("an absolute main file is used as recorded")
    func absolutePathIsUnchanged() {
        #expect(IndexUnitReader.absolute("/pkg/Sources/A.swift", workingDirectory: "/pkg") == "/pkg/Sources/A.swift")
    }

    /// Dated as given, a relative path finds no file, and the unit would be called orphaned.
    @Test("a relative main file is resolved against the compilation's working directory")
    func relativePathIsResolved() {
        #expect(IndexUnitReader.absolute("Sources/A.swift", workingDirectory: "/pkg") == "/pkg/Sources/A.swift")
        #expect(IndexUnitReader.absolute("../shared/A.swift", workingDirectory: "/pkg/app") == "/pkg/shared/A.swift")
    }

    @Test("a relative main file with no working directory is left alone")
    func relativePathWithoutWorkingDirectory() {
        #expect(IndexUnitReader.absolute("Sources/A.swift", workingDirectory: "") == "Sources/A.swift")
    }
}
