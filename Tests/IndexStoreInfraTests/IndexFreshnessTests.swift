import Foundation
import Testing
@testable import IndexStoreInfra

/// Unit tests for `IndexFreshness`, which answers whether an index store was built after the
/// sources it would be read against.
///
/// The fixtures set mtimes explicitly rather than relying on write order: the defect these
/// guard against is precisely a timestamp read from the wrong inode, so the timestamps are
/// the subject of the test and cannot be incidental.
@Suite("IndexFreshness")
struct IndexFreshnessTests {

    private static let old = Date(timeIntervalSince1970: 1_000_000)
    private static let mid = Date(timeIntervalSince1970: 2_000_000)
    private static let recent = Date(timeIntervalSince1970: 3_000_000)

    /// A package root with an index store and a source tree, each stamped explicitly.
    ///
    /// - Parameters:
    ///   - unitDates: One entry per unit file written under `<store>/v5/units`.
    ///   - sourceDates: One entry per `.swift` file written under `Sources`.
    ///   - testDates: One entry per `.swift` file written under `Tests`.
    ///   - storeDirectoryDate: Stamped onto the *top-level* store directory after the units
    ///     are written, to model the frozen-parent case the real tree exhibits.
    private func makeRoot(
        unitDates: [Date],
        sourceDates: [Date],
        testDates: [Date] = [],
        storeDirectoryDate: Date? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("qg-freshness-\(UUID().uuidString)", isDirectory: true)
        let store = root.appendingPathComponent(".build/index-build/index-store", isDirectory: true)
        let units = store.appendingPathComponent("v5/units", isDirectory: true)
        try fm.createDirectory(at: units, withIntermediateDirectories: true)

        for (index, date) in unitDates.enumerated() {
            let unit = units.appendingPathComponent("Module\(index).swift.o-HASH\(index)")
            try Data("unit".utf8).write(to: unit)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: unit.path)
        }

        for (directory, dates) in [("Sources", sourceDates), ("Tests", testDates)] {
            guard !dates.isEmpty else { continue }
            let dir = root.appendingPathComponent(directory, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (index, date) in dates.enumerated() {
                let file = dir.appendingPathComponent("File\(index).swift")
                try Data("struct File\(index) {}".utf8).write(to: file)
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            }
        }

        if let storeDirectoryDate {
            try fm.setAttributes([.modificationDate: storeDirectoryDate], ofItemAtPath: store.path)
        }
        return root
    }

    private func measure(_ root: URL, excludePatterns: [String] = []) -> IndexFreshnessMeasurement {
        IndexFreshness.measure(
            storeURL: root.appendingPathComponent(".build/index-build/index-store"),
            sourceRoots: [
                root.appendingPathComponent("Sources"),
                root.appendingPathComponent("Tests"),
            ],
            excludePatterns: excludePatterns
        )
    }

    @Test("A source newer than every index unit is stale")
    func sourceNewerIsStale() throws {
        let root = try makeRoot(unitDates: [Self.old, Self.mid], sourceDates: [Self.recent])
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .measured(let freshness) = measure(root) else {
            Issue.record("expected a measurement")
            return
        }
        #expect(freshness.isStale)
        #expect(freshness.newestIndexUnit == Self.mid)
        #expect(freshness.newestSource == Self.recent)
        #expect(abs(freshness.lag - 1_000_000) < 1e-6)
    }

    @Test("An index newer than every source is fresh")
    func indexNewerIsFresh() throws {
        let root = try makeRoot(unitDates: [Self.recent], sourceDates: [Self.old, Self.mid])
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .measured(let freshness) = measure(root) else {
            Issue.record("expected a measurement")
            return
        }
        #expect(!freshness.isStale)
        #expect(freshness.unitCount == 1)
    }

    /// The defect this whole proposal exists for.
    ///
    /// `StoreLocator.needsRebuild` stats the top-level store directory, whose mtime does not
    /// move when a file nested under `v5/units` is rewritten — verified against the real tree,
    /// where `index-store` was eight days older than the units inside it. A freshness check
    /// must read the units, so a store directory stamped in the distant past must not make a
    /// current index look stale, and one stamped in the future must not make a stale index
    /// look current.
    @Test("Freshness is read from the units, not from the store directory's own mtime")
    func ignoresStoreDirectoryMtime() throws {
        let fresh = try makeRoot(
            unitDates: [Self.recent],
            sourceDates: [Self.mid],
            storeDirectoryDate: Self.old        // frozen parent, current units
        )
        defer { try? FileManager.default.removeItem(at: fresh) }
        guard case .measured(let freshMeasurement) = measure(fresh) else {
            Issue.record("expected a measurement")
            return
        }
        #expect(!freshMeasurement.isStale)

        let stale = try makeRoot(
            unitDates: [Self.old],
            sourceDates: [Self.mid],
            storeDirectoryDate: Self.recent     // touched parent, stale units
        )
        defer { try? FileManager.default.removeItem(at: stale) }
        guard case .measured(let staleMeasurement) = measure(stale) else {
            Issue.record("expected a measurement")
            return
        }
        #expect(staleMeasurement.isStale)
    }

    /// `needsRebuild` and `freshSwiftbuildStore` both compare against `Sources` alone, so an
    /// edit confined to `Tests` never invalidated the index.
    @Test("A Tests-only edit newer than the index is stale")
    func testsOnlyEditIsStale() throws {
        let root = try makeRoot(
            unitDates: [Self.mid],
            sourceDates: [Self.old],
            testDates: [Self.recent]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .measured(let freshness) = measure(root) else {
            Issue.record("expected a measurement")
            return
        }
        #expect(freshness.isStale)
        #expect(freshness.newestSource == Self.recent)
    }

    @Test("An excluded source cannot make the index look stale")
    func excludedSourceIgnored() throws {
        let root = try makeRoot(unitDates: [Self.mid], sourceDates: [Self.old, Self.recent])
        defer { try? FileManager.default.removeItem(at: root) }

        // File1.swift carries `recent`; excluding it leaves only the `old` source.
        guard case .measured(let freshness) = measure(root, excludePatterns: ["File1.swift"]) else {
            Issue.record("expected a measurement")
            return
        }
        #expect(!freshness.isStale)
        #expect(freshness.newestSource == Self.old)
    }

    /// An unmeasurable store is not a fresh one. Reporting "not stale" here would restore
    /// exactly the assertion this replaces.
    @Test("An empty units directory yields no measurement, not a fresh verdict")
    func emptyUnitsIsNotFresh() throws {
        let root = try makeRoot(unitDates: [], sourceDates: [Self.recent])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(measure(root) == .noIndexUnits)
    }

    @Test("An absent store yields no measurement")
    func absentStoreIsNotFresh() throws {
        let root = try makeRoot(unitDates: [Self.mid], sourceDates: [Self.recent])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".build"))

        #expect(measure(root) == .noIndexUnits)
    }

    @Test("A source tree with no Swift files yields no measurement")
    func noSources() throws {
        let root = try makeRoot(unitDates: [Self.mid], sourceDates: [])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(measure(root) == .noSources)
    }

    @Test("Unit count reports what was examined")
    func unitCountIsReported() throws {
        let root = try makeRoot(
            unitDates: [Self.old, Self.mid, Self.recent],
            sourceDates: [Self.old]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .measured(let freshness) = measure(root) else {
            Issue.record("expected a measurement")
            return
        }
        #expect(freshness.unitCount == 3)
        #expect(freshness.newestIndexUnit == Self.recent)
    }
}
