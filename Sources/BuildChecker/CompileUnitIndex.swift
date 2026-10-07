import Foundation
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
/// - **First-party** — a unit whose source lies under `/.build/` (a dependency checkout or a
///   generated source) is skipped.
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

    /// The marker of a path inside a SwiftPM build directory: dependency checkouts and
    /// generated sources. Units compiled from there are not first-party.
    static let buildDirectoryMarker = "/.build/"

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
        for map in maps.live {
            guard let data = FileManager.default.contents(atPath: map),
                  let parsed = compileUnits(fromOutputFileMap: data) else {
                unreadable.append(map)
                continue
            }
            units.append(contentsOf: parsed)
        }
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
            guard components.dropLast().contains(where: { $0.lowercased() == wanted }) else { continue }
            maps.append((buildDirectory as NSString).appendingPathComponent(relative))
        }
        return maps.sorted()
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
        !source.contains(buildDirectoryMarker) && FileManager.default.fileExists(atPath: source)
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
