import Foundation
import IndexStore
import QualityGateLogging

/// Reads what each unit file in an index store says about itself.
///
/// IndexStoreDB ingests units and answers questions about symbols. It does not expose which
/// source file and which output path a given unit belongs to, and deciding whether a unit
/// describes current source needs exactly that. This reads the unit files directly, through
/// the same `libIndexStore` the compiler wrote them with.
///
/// Kept in its own file because the `IndexStore` module and `IndexStoreDB` both export a type
/// named `IndexStoreLibrary`, and a file that imports both cannot name either.
enum IndexUnitReader {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "IndexUnitReader")

    /// Reads every unit of the store at `store`.
    ///
    /// - Parameters:
    ///   - store: The index store directory (the one that contains `v5`).
    ///   - libPath: Path to `libIndexStore`.
    /// - Returns: One record per readable unit. A unit that will not open is logged and left
    ///   out, which means it is not declared current — the same outcome as being stale.
    /// - Throws: When the library cannot be loaded or the store cannot be opened.
    static func units(inStoreAt store: URL, libPath: URL) async throws -> [IndexUnitRecord] {
        let library = try await IndexStoreLibrary.at(dylibPath: libPath)
        let indexStore = try library.indexStore(at: store)
        let names = indexStore.unitNames(sorted: false).map { $0.string }

        var records: [IndexUnitRecord] = []
        records.reserveCapacity(names.count)
        for name in names {
            do {
                let unit = try indexStore.unit(named: name)
                records.append(IndexUnitRecord(
                    name: name,
                    modified: unit.modificationDate,
                    mainFile: unit.hasMainFile
                        ? absolute(unit.mainFile.string, workingDirectory: unit.workingDirectory.string)
                        : "",
                    outputFile: unit.outputFile.string,
                    moduleName: unit.moduleName.string,
                    target: unit.target.string))
            } catch {
                logger.warning("index unit \(name, privacy: .public) could not be read and will not be consulted: \(String(describing: error), privacy: .public)")
            }
        }
        return records
    }

    /// The main file as an absolute path.
    ///
    /// A compiler invoked with a relative source path records it relative, beside the working
    /// directory it was run in. Dating such a path as given would find no file and call the
    /// unit orphaned — setting aside a unit that is current, for a reason that is not true.
    ///
    /// - Parameters:
    ///   - path: The main file as the unit records it.
    ///   - workingDirectory: The compilation's working directory, as the unit records it.
    /// - Returns: `path` when it is already absolute or there is nothing to resolve it
    ///   against; otherwise `path` resolved against `workingDirectory`.
    static func absolute(_ path: String, workingDirectory: String) -> String {
        guard !path.hasPrefix("/"), !path.isEmpty, !workingDirectory.isEmpty else { return path }
        return URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(path)
            .standardizedFileURL.path
    }
}
