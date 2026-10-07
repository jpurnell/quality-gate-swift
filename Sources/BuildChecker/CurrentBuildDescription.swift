import Foundation
import QualityGateCore
import QualityGateLogging

/// Which output file maps the build that just ran calls its own.
///
/// A build directory outlives the builds that wrote into it. A renamed target, or a variant
/// directory an older toolchain named differently, leaves its output file map and its records
/// on disk; the map still names sources that exist, so by the map alone its units look live.
/// Nothing ever rewrites them.
///
/// The build system knows better, and writes it down. Both build systems leave a description
/// of the build they just planned, and each description names the output file map of every
/// Swift target in it:
///
/// | build system | description | how the map is named |
/// |---|---|---|
/// | swiftbuild | `out/Intermediates.noindex/XCBuildData/<id>.xcbuilddata/manifest.json`, `<id>` being the last line of `prior-build-descriptions.txt` | the output of a `WriteAuxiliaryFile` command |
/// | native | `<configuration>.yaml` | the argument after `-output-file-map` |
///
/// Neither is parsed as a document — the swiftbuild manifest of a 120-target package is tens of
/// megabytes. The file is scanned for quoted strings that end in a map's file name and are an
/// absolute path, which is the same thing in both formats and takes one pass.
///
/// It costs no SwiftPM invocation, and it is only meaningful immediately after a build: the
/// latest description is whichever build ran last.
///
/// ## Usage
///
/// ```swift
/// import BuildChecker
///
/// let index = CompileUnitIndex.scan(buildDirectory: "/path/to/package/.build", configuration: "debug")
/// print("\(index.orphanedUnitCount) unit(s) belong to a build that is gone")
/// ```
enum CurrentBuildDescription {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "CurrentBuildDescription")

    /// Where swiftbuild keeps its build descriptions, relative to the build directory.
    static let swiftbuildDataDirectory = "out/Intermediates.noindex/XCBuildData"

    /// The file-name endings of an output file map under either build system.
    static let outputFileMapSuffixes = ["OutputFileMap.json", "output-file-map.json"]

    /// How far back from a map's file name its opening quote is looked for. Longer than any
    /// path the file system allows.
    static let longestPath = 4096

    /// The output file maps named by the latest build's description.
    ///
    /// - Parameters:
    ///   - buildDirectory: The build directory, usually `<package root>/.build`.
    ///   - configuration: The build configuration name, `debug` or `release`.
    /// - Returns: The maps' paths with symbolic links resolved, or `nil` when no description
    ///   was found or it could not be read — in which case nothing is known about which maps
    ///   are current, and a caller must not call any of them an orphan.
    static func namedOutputFileMaps(buildDirectory: String, configuration: String) -> Set<String>? {
        guard let path = descriptionPath(buildDirectory: buildDirectory, configuration: configuration) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            logger.debug("Unreadable build description \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return Set(outputFileMapPaths(in: data).map(canonical))
    }

    /// The description of the latest build of `configuration`, if one is on disk.
    ///
    /// SwiftPM records which build system last built a configuration in
    /// `.buildSystem_<configuration>`. When that names one, its description is the answer or
    /// there is none; a build directory without the marker — an older toolchain — is answered by
    /// whichever description was written last.
    ///
    /// - Parameters:
    ///   - buildDirectory: The build directory.
    ///   - configuration: The build configuration name.
    /// - Returns: The description's path, or `nil`.
    static func descriptionPath(buildDirectory: String, configuration: String) -> String? {
        let name = configuration.lowercased()
        let swiftbuild = swiftbuildManifest(buildDirectory: buildDirectory)
        let native = nativeManifest(buildDirectory: buildDirectory, configuration: name)

        switch buildSystem(buildDirectory: buildDirectory, configuration: name) {
        case "swiftbuild":
            return swiftbuild
        case "native":
            return native
        default:
            guard let swiftbuild else { return native }
            guard let native else { return swiftbuild }
            guard let swiftbuildWritten = CompileUnitIndex.modificationDate(atPath: swiftbuild),
                  let nativeWritten = CompileUnitIndex.modificationDate(atPath: native) else {
                return nil
            }
            return swiftbuildWritten >= nativeWritten ? swiftbuild : native
        }
    }

    /// The build system SwiftPM says last built `configuration`, or `nil` when it left no marker.
    ///
    /// The configuration name comes from the project's configuration file, so a name that would
    /// lead out of the build directory is not followed.
    static func buildSystem(buildDirectory: String, configuration: String) -> String? {
        let directory = URL(fileURLWithPath: buildDirectory).resolvingSymlinksInPath()
        let marker = directory.appendingPathComponent(".buildSystem_\(configuration)").resolvingSymlinksInPath()
        guard marker.pathComponents.starts(with: directory.pathComponents),
              let data = FileManager.default.contents(atPath: marker.path) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The native build system's llbuild manifest for `configuration`, if there is one inside
    /// the build directory.
    static func nativeManifest(buildDirectory: String, configuration: String) -> String? {
        let directory = URL(fileURLWithPath: buildDirectory).resolvingSymlinksInPath()
        let manifest = directory.appendingPathComponent("\(configuration).yaml").resolvingSymlinksInPath()
        guard manifest.pathComponents.starts(with: directory.pathComponents),
              FileManager.default.fileExists(atPath: manifest.path) else {
            return nil
        }
        return manifest.path
    }

    /// The manifest of swiftbuild's latest build description, if there is one.
    ///
    /// swiftbuild appends the identifier of the description it used to
    /// `prior-build-descriptions.txt` on every build, a reused description included, so the
    /// last line is the build that just ran.
    static func swiftbuildManifest(buildDirectory: String) -> String? {
        let data = URL(fileURLWithPath: buildDirectory)
            .appendingPathComponent(swiftbuildDataDirectory)
            .resolvingSymlinksInPath()
        guard let list = FileManager.default.contents(atPath: data.appendingPathComponent("prior-build-descriptions.txt").path) else {
            return nil
        }
        let identifiers = String(decoding: list, as: UTF8.self).lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let latest = identifiers.last else { return nil }
        // The identifier is read from a file. It is a hash, and a description lives inside the
        // data directory; a line that would lead anywhere else is not followed.
        let manifest = data
            .appendingPathComponent("\(latest).xcbuilddata")
            .appendingPathComponent("manifest.json")
            .resolvingSymlinksInPath()
        guard manifest.pathComponents.starts(with: data.pathComponents),
              FileManager.default.fileExists(atPath: manifest.path) else {
            return nil
        }
        return manifest.path
    }

    /// Every absolute path to an output file map that appears as a whole quoted string.
    ///
    /// A description also mentions a map inside longer strings — a command's name, its
    /// description — and those are not the map being named as a file. Only a string that is
    /// the path, start to end, counts.
    ///
    /// - Parameter data: The description's bytes, JSON or llbuild's YAML.
    /// - Returns: The paths, unescaped, as written.
    static func outputFileMapPaths(in data: Data) -> Set<String> {
        var paths = Set<String>()
        for suffix in outputFileMapSuffixes {
            let needle = Data((suffix + "\"").utf8)
            var from = data.startIndex
            while from < data.endIndex, let hit = data.range(of: needle, in: from..<data.endIndex) {
                from = hit.upperBound
                let floor = max(data.startIndex, hit.lowerBound - longestPath)
                // No opening quote within reach: not a string this scan understands.
                guard let opening = openingQuote(before: hit.lowerBound, notBefore: floor, in: data) else {
                    continue
                }
                if let path = string(fromQuoted: data[opening..<hit.upperBound]), path.hasPrefix("/") {
                    paths.insert(path)
                }
            }
        }
        return paths
    }

    /// The index of the quote that opens the string ending at `end`: the nearest one before it
    /// that is not itself escaped.
    private static func openingQuote(before end: Data.Index, notBefore floor: Data.Index, in data: Data) -> Data.Index? {
        let quote = UInt8(ascii: "\"")
        let backslash = UInt8(ascii: "\\")
        var index = end
        while index > floor {
            index -= 1
            guard data[index] == quote else { continue }
            var escapes = 0
            var before = index
            while before > floor, data[before - 1] == backslash {
                escapes += 1
                before -= 1
            }
            if escapes.isMultiple(of: 2) { return index }
        }
        return nil
    }

    /// Decodes one quoted string, escapes included. Both formats quote a path as JSON does.
    private static func string(fromQuoted token: Data) -> String? {
        do {
            return try JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String
        } catch {
            logger.debug("Not a quoted string in a build description: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A path with symbolic links resolved, so that the spelling a description uses and the
    /// spelling a directory walk produces compare equal.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
