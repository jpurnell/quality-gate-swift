import Foundation
import QualityGateLogging

/// Whether an index store was built with the package's test targets in it.
///
/// `swift build` compiles the library alone; the test targets enter the index only when the
/// build asks for them with `--build-tests`. A store without them answers every question about
/// reachability in one direction: a symbol that only a test suite calls has no references at
/// all, and reads as dead.
///
/// That is worse than an incomplete answer, because the finding it produces —
/// `unreachable from any entry point` — is *identical in form* to a correct one. A reader
/// cannot tell them apart, and the remedy the diagnostic suggests is deletion of live code.
/// SwiftXLSX's CI reported exactly that against a 182-unit index while the same commit passed
/// locally against a 453-unit one, and the difference was the test targets.
public enum IndexTestCoverage {

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.quality-gate", category: "IndexTestCoverage")
    #endif

    /// Whether `store` holds a unit compiled from one of the package's test sources.
    ///
    /// Matched on file *basenames* rather than module names: a unit is named after the source
    /// it came from, and the mapping from a target to its module name is SwiftPM's to know.
    /// Basenames are what both sides agree on without asking the manifest.
    ///
    /// - Parameters:
    ///   - store: The index store directory. Units are read from `v5/units` beneath it.
    ///   - packageRoot: The package root, whose `Tests/` tree names the sources in question.
    /// - Returns: `true` when at least one test source has a unit; `false` when the package has
    ///   test sources and none of them does; `nil` when the question does not apply (no test
    ///   sources) or cannot be answered (no readable units directory). A `nil` is deliberately
    ///   not a `false`: a caller must not raise a barrier over a question nobody asked.
    public static func includesTestUnits(store: URL, packageRoot: URL) -> Bool? {
        let testBasenames = testSourceBasenames(packageRoot: packageRoot)
        guard !testBasenames.isEmpty else { return nil }

        let units = StoreLocator.unitsDirectory(in: store)
        let manager = FileManager.default
        // SAFETY: read-only probe of the project's own index store
        guard manager.fileExists(atPath: units.path) else { return nil }

        let entries: [URL]
        do {
            entries = try manager.contentsOfDirectory(
                at: units, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            #if canImport(os)
            logger.warning("index units exist but will not enumerate; test coverage of the index is unknown: \(error.localizedDescription, privacy: .public)")
            #endif
            return nil
        }
        guard !entries.isEmpty else { return nil }

        for entry in entries {
            let name = entry.lastPathComponent
            if testBasenames.contains(where: { name.contains($0) }) { return true }
        }
        return false
    }

    /// The basenames, without extension, of every `.swift` file under `Tests/`.
    private static func testSourceBasenames(packageRoot: URL) -> Set<String> {
        let tests = packageRoot.appendingPathComponent("Tests", isDirectory: true)
        let manager = FileManager.default
        // SAFETY: read-only walk of the project's own test sources
        guard manager.fileExists(atPath: tests.path) else { return [] }
        guard let walker = manager.enumerator(
            at: tests, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        var names: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            names.insert(url.deletingPathExtension().lastPathComponent)
        }
        return names
    }
}
