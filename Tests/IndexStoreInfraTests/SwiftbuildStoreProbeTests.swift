import Foundation
import Testing
@testable import IndexStoreInfra

/// Empirical probe: can `IndexStoreDB` open and query the index store that
/// swiftbuild (the Swift 6.4 default build system) emits at `.build/out`
/// during a normal `swift build` — with NO separate `--build-system native`
/// compile? If yes, the double-compile that times out CI is unnecessary.
///
/// This is a validation spike, not a permanent assertion: it depends on a
/// prior `swift build` having populated `.build/out/v5`. It is skipped when
/// that store is absent so it never fails a clean checkout.
@Suite("Swiftbuild default-store probe")
struct SwiftbuildStoreProbeTests {

    @Test("IndexStoreDB opens .build/out and returns symbols for our own sources")
    func swiftbuildStoreIsQueryable() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let store = root.appendingPathComponent(".build/out")
        let v5 = store.appendingPathComponent("v5/units")
        guard FileManager.default.fileExists(atPath: v5.path) else {
            // No swiftbuild store present (e.g. a native-only or clean build) — nothing to probe.
            return
        }
        guard let lib = IndexStoreSession.findLibIndexStore() else {
            Issue.record("libIndexStore.dylib not found via active toolchain")
            return
        }

        let session = try IndexStoreSession(storePath: store, libPath: lib)

        // Query a known first-party source file. If the store is genuinely
        // queryable, this returns the declarations defined in that file.
        let target = root.appendingPathComponent("Sources/RecursionAuditor/RecursionAuditor.swift").path
        let symbols = session.db.symbols(inFilePath: target)

        #expect(!symbols.isEmpty,
                "swiftbuild's .build/out store returned no symbols for RecursionAuditor.swift — not usable as a drop-in index")
    }
}
