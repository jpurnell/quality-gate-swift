import Foundation
import QualityGateCore
import QualityGateLogging

/// One compile job the build system knows about, and where it records its diagnostics.
public struct CompileUnit: Sendable, Equatable {
    /// The source file this job compiles, or `nil` for a module-level job (emit-module, or a
    /// whole-module compile) that reads every source in its target.
    public let source: String?

    /// Where the compiler writes this job's serialized diagnostics.
    public let diagnosticsPath: String

    /// For a module-level unit, every live first-party source in the same output file map.
    /// Empty for a per-file unit.
    public let siblings: [String]

    /// Creates a compile unit.
    ///
    /// - Parameters:
    ///   - source: The source file compiled, or `nil` for a module-level unit.
    ///   - diagnosticsPath: The `.dia` file the job writes.
    ///   - siblings: For a module-level unit, the sources it reads.
    public init(source: String?, diagnosticsPath: String, siblings: [String] = []) {
        self.source = source
        self.diagnosticsPath = diagnosticsPath
        self.siblings = siblings
    }

    /// The source files this unit's record must not be older than: its own source, or for a
    /// module-level unit every sibling.
    public var inputs: [String] {
        if let source { return [source] }
        return siblings
    }
}

/// The compile units a build directory describes for one configuration.
///
/// The index is built from **output file maps** — the JSON the build system hands the Swift
/// driver to say where each job's outputs go — and from nothing else. It does not look for
/// `.dia` files: a `.dia` on disk for a source file that was since deleted still holds that
/// file's warnings, and only the map says which records belong to the current build.
///
/// Three rules are applied while indexing, before any record is read:
///
/// - **Live** — a unit exists only if a map names it and its source file exists.
/// - **Of this build** — a map the latest build's own description does not name is an orphan:
///   left by a target since renamed, or by a variant directory an older toolchain named
///   differently. Its units are counted in ``orphanedUnitCount`` and are otherwise not there.
///   See ``scan(buildDirectory:configuration:)`` for when nothing is called an orphan.
/// - **First-party** — a unit whose source `DependencyOrigin` attributes to a dependency or
///   to the build directory (`/.build/`: a checkout or a generated source) is skipped.
///
/// ## Usage
///
/// ```swift
/// import BuildChecker
///
/// let index = CompileUnitIndex.scan(buildDirectory: "/path/to/package/.build", configuration: "debug")
/// for unit in index.units where !CompileUnitIndex.isCurrent(unit) {
///     print("stale record: \(unit.diagnosticsPath)")
/// }
/// ```
public struct CompileUnitIndex: Sendable, Equatable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "CompileUnitIndex")

    /// The live, first-party compile units, in map order.
    public let units: [CompileUnit]

    /// How many output file maps of the build that just ran were found for the configuration.
    /// Orphaned maps are not among them.
    public let mapCount: Int

    /// Output file maps that were found but could not be read as a map.
    public let unreadableMaps: [String]

    /// Output file maps on disk that the latest build does not name, and that describe at least
    /// one live first-party unit. An orphaned map of a dependency is not listed: none of its
    /// units would have been read either way.
    public let orphanedMaps: [String]

    /// How many live first-party units ``orphanedMaps`` describe. They are in no count but this
    /// one: not read, and not reported as unread.
    public let orphanedUnitCount: Int

    /// Creates an index from its parts.
    ///
    /// - Parameters:
    ///   - units: The live, first-party compile units.
    ///   - mapCount: How many output file maps were found.
    ///   - unreadableMaps: Maps that could not be parsed.
    ///   - orphanedMaps: Maps the latest build does not name.
    ///   - orphanedUnitCount: The live first-party units those maps describe.
    public init(
        units: [CompileUnit],
        mapCount: Int,
        unreadableMaps: [String] = [],
        orphanedMaps: [String] = [],
        orphanedUnitCount: Int = 0
    ) {
        self.units = units
        self.mapCount = mapCount
        self.unreadableMaps = unreadableMaps
        self.orphanedMaps = orphanedMaps
        self.orphanedUnitCount = orphanedUnitCount
    }

    /// Directory names under a build directory that never contain an output file map and are
    /// not worth walking: dependency sources, their bare repositories, binary artifacts, and
    /// the module and compilation caches.
    static let prunedDirectoryNames: Set<String> = [
        "checkouts", "repositories", "artifacts", "prebuilts", "registry",
        "ModuleCache", "ModuleCache.noindex", "CompilationCache.noindex", "SDKStatCaches.noindex",
    ]

    /// Indexes the compile units of one build configuration.
    ///
    /// A map belongs to `configuration` when its path, relative to `buildDirectory`, has a
    /// component equal to the configuration name ignoring case — `Debug/` under the `swiftbuild`
    /// build system, `debug/` under the native one.
    ///
    /// A map is then kept only if the latest build's description names it — see
    /// `CurrentBuildDescription`. That is a statement about the build that ran last, so call
    /// this straight after the build whose records are wanted. Nothing is called an orphan on a
    /// guess: when no description is found, or the one found names none of the configuration's
    /// maps (it describes some other build — a release one, say), every map is kept.
    ///
    /// - Parameters:
    ///   - buildDirectory: The build directory, usually `<package root>/.build`.
    ///   - configuration: The build configuration name, `debug` or `release`.
    /// - Returns: The index. It is empty — `mapCount == 0` — when the directory holds no map
    ///   for the configuration, which a caller must treat as "could not look", not as "clean".
    public static func scan(buildDirectory: String, configuration: String) -> CompileUnitIndex {
        let found = outputFileMaps(under: buildDirectory, configuration: configuration)
        let maps = partition(
            found,
            namedByLatestBuild: CurrentBuildDescription.namedOutputFileMaps(
                buildDirectory: buildDirectory, configuration: configuration)
        )
        var units: [CompileUnit] = []
        var unreadable: [String] = []
        var namedRecords: Set<String> = []
        for map in maps.live {
            guard let data = FileManager.default.contents(atPath: map),
                  let parsed = compileUnits(fromOutputFileMap: data) else {
                unreadable.append(map)
                continue
            }
            units.append(contentsOf: parsed)
            namedRecords.formUnion(recordsNamed(byOutputFileMap: data))
        }
        units = resolvingWholeModuleRecords(units, namedRecords: namedRecords)
        var orphanedMaps: [String] = []
        var orphanedUnitCount = 0
        for map in maps.orphaned {
            guard let data = FileManager.default.contents(atPath: map),
                  let parsed = compileUnits(fromOutputFileMap: data), !parsed.isEmpty else {
                continue
            }
            orphanedMaps.append(map)
            orphanedUnitCount += parsed.count
        }
        return CompileUnitIndex(
            units: units,
            mapCount: maps.live.count,
            unreadableMaps: unreadable,
            orphanedMaps: orphanedMaps,
            orphanedUnitCount: orphanedUnitCount
        )
    }

    /// Substitutes the module-level record for per-file units whose records were never written.
    ///
    /// The native build system's output file map has the same shape in both compilation modes:
    /// every source carries a `diagnostics` entry and the `""` key carries none. Under
    /// whole-module — any release build, and what Swift 6.2 runs on Linux — those per-file
    /// records are not written. The compiler writes one `<Module>.dia` that the map never names.
    ///
    /// So ``compileUnits(fromOutputFileMap:)`` cannot tell the modes apart, and its documented
    /// claim that it can was true only of `swiftbuild`'s maps. The question is answered here
    /// instead, where the filesystem is already being read, leaving that function a pure function
    /// of the map.
    ///
    /// A group of per-file units sharing a record directory is replaced by a single module-level
    /// unit when **none** of their records exist and exactly one unclaimed `.dia` sits in that
    /// directory. Both halves matter: one existing per-file record means the build was per-file,
    /// and more than one unclaimed record means the answer is not obvious — in which case nothing
    /// is substituted and the units are reported unverified, as before. Absence stays absence.
    ///
    /// Attribution does not depend on which unit found the record: a `.dia` names the absolute
    /// source path of every diagnostic it holds.
    ///
    /// See `quality-gate-swift-project/plans/proposals/TheMapCannotTellYouWhichModeRan.md`.
    static func resolvingWholeModuleRecords(
        _ units: [CompileUnit], namedRecords: Set<String>
    ) -> [CompileUnit] {
        let byDirectory = Dictionary(grouping: units.filter { $0.source != nil }) {
            ($0.diagnosticsPath as NSString).deletingLastPathComponent
        }
        var substitute: [String: CompileUnit] = [:]
        for (directory, group) in byDirectory {
            guard !group.contains(where: { FileManager.default.fileExists(atPath: $0.diagnosticsPath) }),
                  let record = unclaimedRecord(in: directory, named: namedRecords) else { continue }
            substitute[directory] = CompileUnit(
                source: nil,
                diagnosticsPath: record,
                siblings: group.compactMap(\.source).sorted()
            )
        }
        guard !substitute.isEmpty else { return units }

        // Rebuilt in map order, each substitution standing where its group's first unit stood.
        var result: [CompileUnit] = []
        var emitted: Set<String> = []
        for unit in units {
            guard unit.source != nil else { result.append(unit); continue }
            let directory = (unit.diagnosticsPath as NSString).deletingLastPathComponent
            guard let replacement = substitute[directory] else { result.append(unit); continue }
            if emitted.insert(directory).inserted { result.append(replacement) }
        }
        return result
    }

    /// The single `.dia` in `directory` that no output file map names, or `nil` if there is not
    /// exactly one.
    ///
    /// The exclusion is every record the maps name, not merely those of the units that survived
    /// filtering. A deleted source leaves its record on disk while its map entry yields no unit,
    /// so a set built from units alone would offer that orphan as the module record — which it
    /// did, and an existing test said so. The module record is the one the map is silent about.
    static func unclaimedRecord(in directory: String, named: Set<String>) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        let namedHere = Set(named.map { ($0 as NSString).lastPathComponent })
        let candidates = entries
            .filter { $0.hasSuffix(".dia") && !namedHere.contains($0) }
            .sorted()
        guard candidates.count == 1, let only = candidates.first else { return nil }
        return (directory as NSString).appendingPathComponent(only)
    }

    /// Every serialized-diagnostics path an output file map names, whatever became of its source.
    ///
    /// Pure, like ``compileUnits(fromOutputFileMap:)``: it reports what the map says and consults
    /// nothing on disk.
    static func recordsNamed(byOutputFileMap data: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let entries = object as? [String: [String: Any]] else { return [] }
        var records: Set<String> = []
        for (_, entry) in entries {
            for key in ["diagnostics", "emit-module-diagnostics"] {
                if let path = entry[key] as? String { records.insert(path) }
            }
        }
        return records
    }

    /// Splits the maps on disk into those the latest build names and those it does not.
    ///
    /// - Parameters:
    ///   - maps: Every map found for the configuration.
    ///   - named: The maps the latest build's description names, symbolic links resolved, or
    ///     `nil` when there is no description to ask.
    /// - Returns: The live maps and the orphans. Every map is live when `named` is `nil` or
    ///   names none of `maps`.
    static func partition(
        _ maps: [String],
        namedByLatestBuild named: Set<String>?
    ) -> (live: [String], orphaned: [String]) {
        guard let named else { return (maps, []) }
        var live: [String] = []
        var orphaned: [String] = []
        for map in maps {
            if named.contains(CurrentBuildDescription.canonical(map)) {
                live.append(map)
            } else {
                orphaned.append(map)
            }
        }
        guard !live.isEmpty else { return (maps, []) }
        return (live, orphaned)
    }

    /// Finds the output file maps for one configuration under a build directory.
    ///
    /// - Parameters:
    ///   - buildDirectory: The build directory to walk.
    ///   - configuration: The build configuration name.
    /// - Returns: Absolute paths of the maps, sorted so the index is deterministic.
    static func outputFileMaps(under buildDirectory: String, configuration: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: buildDirectory) else { return [] }
        let wanted = configuration.lowercased()
        var maps: [String] = []
        while let relative = walker.nextObject() as? String {
            let components = relative.split(separator: "/")
            guard let name = components.last else { continue }
            if prunedDirectoryNames.contains(String(name)) {
                walker.skipDescendants()
                continue
            }
            guard name.hasSuffix("OutputFileMap.json") || name == "output-file-map.json" else { continue }
            guard components.dropLast().contains(where: { belongs($0.lowercased(), to: wanted) }) else { continue }
            maps.append((buildDirectory as NSString).appendingPathComponent(relative))
        }
        return maps.sorted()
    }

    /// Whether a lower-cased path component names `configuration`.
    ///
    /// Exact equality is not enough. `swiftbuild` names its configuration directory
    /// `<Configuration>` on Darwin but `<Configuration>-<platform>-<arch>` elsewhere — a
    /// Swift 6.4 Linux build writes `Release-linux-x86_64`. Requiring equality found all 98
    /// maps such a build produces and then discarded every one of them, so `mapCount` reached
    /// zero and `build` reported "No output file map was found in the build directory". That
    /// was accurate about what it could see and wrong about what was there: eleven
    /// `WarmBuildTests` failures on 6.4 and none on 6.2, which still uses the native build
    /// system and does have a literal `release` component.
    ///
    /// The prefix must be followed by `-`, so `release` does not match `released` or a
    /// directory merely starting with the word. A different configuration is still excluded
    /// however its platform suffix is spelled, which is the property the paired test pins —
    /// widening this must not make the configuration filter decorative.
    static func belongs(_ component: String, to configuration: String) -> Bool {
        component == configuration || component.hasPrefix(configuration + "-")
    }

    /// Parses one output file map into its live, first-party compile units.
    ///
    /// Per-file units come from each source's `diagnostics` entry. The `""` key describes the
    /// module as a whole, and which of its entries is a real job depends on how the target is
    /// compiled: when sources have their own `diagnostics` (one job per file), the module-level
    /// job is emit-module and its record is `emit-module-diagnostics`; when they have none
    /// (whole-module), the single compile job's record is the `""` key's `diagnostics`. The
    /// map names both in either mode, and the one that does not apply is never written — so the
    /// choice is made here, from the map, rather than by looking for whichever file exists.
    ///
    /// - Parameter data: The map's JSON.
    /// - Returns: The units, or `nil` when `data` is not an output file map.
    static func compileUnits(fromOutputFileMap data: Data) -> [CompileUnit]? {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            logger.debug("Output file map is not JSON: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let map = object as? [String: Any] else { return nil }

        var perFile: [CompileUnit] = []
        var liveSources: [String] = []
        for source in map.keys.sorted() where !source.isEmpty && isLiveFirstParty(source) {
            liveSources.append(source)
            if let record = (map[source] as? [String: Any])?["diagnostics"] as? String {
                perFile.append(CompileUnit(source: source, diagnosticsPath: record))
            }
        }
        // A module none of whose sources is live and first-party — a dependency, or a target
        // whose files are gone — contributes nothing, module-level record included.
        guard !liveSources.isEmpty else { return [] }

        var units = perFile
        if let module = map[""] as? [String: Any] {
            let key = perFile.isEmpty ? "diagnostics" : "emit-module-diagnostics"
            if let record = module[key] as? String {
                units.append(CompileUnit(source: nil, diagnosticsPath: record, siblings: liveSources))
            }
        }
        return units
    }

    /// Whether `source` exists and is not inside a build directory.
    static func isLiveFirstParty(_ source: String) -> Bool {
        // `DependencyOrigin` is the gate's one definition of whose a path is; a unit this
        // index skips and a diagnostic the checker scopes out are decided by the same rule.
        DependencyOrigin.of(path: source, projectRoot: nil) == nil
            && FileManager.default.fileExists(atPath: source)
    }

    /// Whether a unit's record is no older than every source it was compiled from.
    ///
    /// After a successful build this holds for every live unit by construction — the build
    /// system recompiled whatever was out of date. It is checked because the alternative is
    /// assuming it: after a *failed* build, the failing file's record is the previous one.
    ///
    /// - Parameter unit: The unit to check.
    /// - Returns: `false` when the record is missing, or older than any of ``CompileUnit/inputs``.
    public static func isCurrent(_ unit: CompileUnit) -> Bool {
        guard let recorded = modificationDate(atPath: unit.diagnosticsPath) else { return false }
        return unit.inputs.allSatisfy { input in
            guard let edited = modificationDate(atPath: input) else { return false }
            return recorded >= edited
        }
    }

    /// The modification date of the file at `path`, or `nil` when it cannot be read.
    static func modificationDate(atPath path: String) -> Date? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            logger.debug("No modification date for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}
