import Foundation
import Testing
@testable import IndexStoreInfra

/// Tests that a located store reports a *measured* age rather than an asserted one.
///
/// `StoreLocator.locate` returned `LocatedStore(url:, isStale: false)` on the SwiftPM path
/// without measuring anything, on the theory that `ensureFresh` had guaranteed freshness.
/// It cannot: `needsRebuild` stats the top-level store directory, whose mtime does not move
/// when a unit nested under `v5/units` is rewritten. Every checker downstream — and there are
/// seven — was reading a flag hardcoded to `false`.
///
/// These exercise the seam directly rather than `locate`, which would run a real `swift build`.
@Suite("StoreLocator freshness")
struct StoreLocatorFreshnessTests {

    private static let old = Date(timeIntervalSince1970: 1_000_000)
    private static let mid = Date(timeIntervalSince1970: 2_000_000)
    private static let recent = Date(timeIntervalSince1970: 3_000_000)

    private func makeRoot(unitDates: [Date], sourceDate: Date) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("qg-locator-fresh-\(UUID().uuidString)", isDirectory: true)
        let units = root
            .appendingPathComponent(".build/index-build/index-store/v5/units", isDirectory: true)
        try fm.createDirectory(at: units, withIntermediateDirectories: true)
        for (index, date) in unitDates.enumerated() {
            let unit = units.appendingPathComponent("Module\(index).swift.o-HASH\(index)")
            try Data("unit".utf8).write(to: unit)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: unit.path)
        }
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Thing.swift")
        try Data("struct Thing {}".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: sourceDate], ofItemAtPath: file.path)
        return root
    }

    private func locate(_ root: URL) -> StoreLocator.LocatedStore {
        StoreLocator.located(
            store: root.appendingPathComponent(".build/index-build/index-store"),
            projectRoot: root,
            excludePatterns: []
        )
    }

    @Test("A store older than the sources is reported stale, not asserted fresh")
    func staleStoreIsReportedStale() throws {
        let root = try makeRoot(unitDates: [Self.old], sourceDate: Self.recent)
        defer { try? FileManager.default.removeItem(at: root) }

        let located = locate(root)
        #expect(located.isStale)
        guard case .measured(let freshness) = located.measurement else {
            Issue.record("expected a measurement to back the verdict")
            return
        }
        #expect(freshness.newestIndexUnit == Self.old)
        #expect(freshness.newestSource == Self.recent)
    }

    @Test("A store newer than the sources is fresh, and says why")
    func freshStoreIsReportedFresh() throws {
        let root = try makeRoot(unitDates: [Self.recent], sourceDate: Self.mid)
        defer { try? FileManager.default.removeItem(at: root) }

        let located = locate(root)
        #expect(!located.isStale)
        guard case .measured = located.measurement else {
            Issue.record("expected a measurement to back the verdict")
            return
        }
    }

    /// An index with no units is not a fresh index. It is also not a stale one — nothing was
    /// dated — so the verdict must carry which of the two it was rather than collapsing to a
    /// bare `false` that reads identically to a measured pass.
    /// Freshness must be measured against every directory that contributes units to the
    /// store, not against a hardcoded `Sources`/`Tests` pair.
    ///
    /// SwiftPM target paths are configurable, and this project has already been bitten by the
    /// assumption once: `doc-code` would have discovered zero articles in a `Source/`-laid-out
    /// package and reported a pass. A layout the walk does not know about produces the silent
    /// failure — an index that measures fresh while the code it describes has moved on.
    @Test("Sources outside Sources/ and Tests/ still count toward freshness")
    func nonStandardLayoutCountsTowardFreshness() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("qg-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let units = root
            .appendingPathComponent(".build/index-build/index-store/v5/units", isDirectory: true)
        try fm.createDirectory(at: units, withIntermediateDirectories: true)
        let unit = units.appendingPathComponent("Mod.swift.o-HASH")
        try Data("unit".utf8).write(to: unit)
        try fm.setAttributes([.modificationDate: Self.old], ofItemAtPath: unit.path)

        // A layout SwiftPM permits and this walk did not know about.
        let modules = root.appendingPathComponent("Modules/Thing", isDirectory: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        let file = modules.appendingPathComponent("Thing.swift")
        try Data("struct Thing {}".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: Self.recent], ofItemAtPath: file.path)

        let located = locate(root)
        #expect(located.isStale)
    }

    /// Build products must not count. `.build` holds checkout sources far newer than the
    /// index that describes the project's own code, and letting them in would barrier every
    /// run after any dependency resolve — a false barrier is loud, but it is still false.
    @Test("Files under .build do not count toward freshness")
    func buildDirectoryIsNotASource() throws {
        let fm = FileManager.default
        let root = try makeRoot(unitDates: [Self.mid], sourceDate: Self.old)
        defer { try? fm.removeItem(at: root) }
        let checkout = root
            .appendingPathComponent(".build/checkouts/Dep/Sources", isDirectory: true)
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        let file = checkout.appendingPathComponent("Dep.swift")
        try Data("struct Dep {}".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: Self.recent], ofItemAtPath: file.path)

        #expect(!locate(root).isStale)
    }

    @Test("An unmeasurable store is distinguishable from a fresh one")
    func unmeasurableStoreIsNotSilentlyFresh() throws {
        let root = try makeRoot(unitDates: [], sourceDate: Self.recent)
        defer { try? FileManager.default.removeItem(at: root) }

        let located = locate(root)
        #expect(located.measurement == .noIndexUnits)
        #expect(!located.isStale)   // and not stale either — nothing was dated
    }
}
