import Foundation
import Testing
import QualityGateCore
@testable import IndexStoreInfra

@Suite("SourceCacheInputs")
struct SourceCacheInputsTests {

    @Test("Scopes to Sources/Tests + manifests, and does NOT descend into .build")
    func scopedToSourcesNotBuild() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qg-sci-\(UUID().uuidString)")
        // A miniature project layout, including a .build/checkouts dependency source.
        let layout = [
            "Sources/App/a.swift",
            "Tests/AppTests/b.swift",
            ".build/checkouts/Dep/c.swift",   // must be excluded — this was the perf bug
            "Package.swift",
        ]
        for rel in layout {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// x".write(to: url, atomically: true, encoding: .utf8)
        }

        let inputs = SourceCacheInputs.wholeSource(projectRoot: root, configuration: Configuration())

        #expect(inputs.files.contains { $0.hasSuffix("Sources/App/a.swift") })
        #expect(inputs.files.contains { $0.hasSuffix("Tests/AppTests/b.swift") })
        #expect(inputs.files.contains { $0.hasSuffix("Package.swift") })
        #expect(inputs.files.contains { $0.hasSuffix("Package.resolved") })  // included even if absent
        // The regression guard: never hash the dependency tree under .build.
        #expect(!inputs.files.contains { $0.contains("/.build/") })
    }
}
