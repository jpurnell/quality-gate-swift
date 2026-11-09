import Foundation
import IndexStoreInfra
import QualityGateCore
import QualityGateLogging

/// Finds the app targets of a project and the sources each one compiles.
///
/// Source scanning alone cannot say which target a file belongs to, nor which platform it
/// builds for, nor whether the target is an app rather than a framework or extension. Two
/// readers supply that:
///
/// - **Xcode projects** (`*.xcodeproj` beside the gate's working directory): each
///   `PBXNativeTarget` whose `productType` begins `com.apple.product-type.application` is an
///   app target (watch apps included; app extensions and test bundles are not). Its files come
///   from the Sources build phase and from synchronized folders, less the folder's membership
///   exceptions; its platforms come from `SDKROOT`, or `SUPPORTED_PLATFORMS` when `SDKROOT` is
///   `auto`.
/// - **SwiftPM layout** (`Sources/<Name>/`): each directory is a target, platform unknown.
///
/// When a readable `.xcodeproj` exists it is authoritative and the `Sources/` layout is not
/// scanned, so a file no app target compiles (an extension's, a framework's) is never flagged.
enum MetricKitTargetDiscovery {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "MetricKitTargetDiscovery")

    /// Lists a directory, logging and returning nothing when it cannot be read.
    private static func entries(of directory: String) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            logger.warning("Could not list \(directory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func discover(root: URL, excludePatterns: [String]) -> [MetricKitTarget] {
        var targets: [MetricKitTarget] = []
        let projects = xcodeProjects(in: root)

        for project in projects {
            for target in XcodeAppTargetReader(project: project).appTargets() {
                let files = swiftFiles(target.paths, excluded: excludePatterns)
                guard !files.isEmpty else { continue }
                targets.append(MetricKitTarget(name: target.name, platforms: target.platforms, files: files))
            }
        }

        // An Xcode project is authoritative: files in `Sources/` that no app target compiles belong
        // to an extension or framework, and guessing a target for them would flag those.
        guard projects.isEmpty else { return targets }

        for (name, paths) in swiftPMTargets(root: root) {
            let files = swiftFiles(paths, excluded: excludePatterns)
            guard !files.isEmpty else { continue }
            targets.append(MetricKitTarget(name: name, platforms: [], files: files))
        }
        return targets
    }

    private static func xcodeProjects(in root: URL) -> [PBXProjectObjects] {
        let names = entries(of: root.path)
        return names.sorted().filter { $0.hasSuffix(".xcodeproj") }.compactMap {
            PBXProjectObjects.load(pbxproj: root.appendingPathComponent($0).appendingPathComponent("project.pbxproj"))
        }
    }

    private static func swiftPMTargets(root: URL) -> [(String, [String])] {
        let sources = root.appendingPathComponent("Sources")
        let names = entries(of: sources.path)
        var out: [(String, [String])] = []
        var loose: [String] = []
        for entry in names.sorted() {
            let path = sources.appendingPathComponent(entry).path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                out.append((entry, [path]))
            } else if entry.hasSuffix(".swift") {
                loose.append(path)
            }
        }
        if !loose.isEmpty { out.append(("Sources", loose)) }
        return out
    }

    /// Reads every `.swift` file under the given files and directories, skipping tests and excluded paths.
    private static func swiftFiles(_ paths: [String], excluded: [String]) -> [MetricKitSourceFile] {
        var seen = Set<String>()
        var out: [MetricKitSourceFile] = []
        func add(_ path: String) {
            guard path.hasSuffix(".swift"), seen.insert(path).inserted else { return }
            if path.contains("/Tests/") || path.contains("/.build/") { return }
            let skip = excluded.contains { pattern in
                path.contains(pattern.replacingOccurrences(of: "**/", with: "").replacingOccurrences(of: "/**", with: ""))
            }
            guard !skip else { return }
            do {
                out.append(MetricKitSourceFile(path: path, source: try String(contentsOfFile: path, encoding: .utf8)))
            } catch {
                logger.warning("Could not read \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                for entry in FileTreeWalker(root: path) { add(entry.path) }
            } else {
                add(path)
            }
        }
        return out.sorted { $0.path < $1.path }
    }
}

/// Reads app targets out of one parsed `project.pbxproj`.
struct XcodeAppTargetReader {
    struct AppTarget {
        let name: String
        let platforms: [String]
        /// Files and directories the target compiles; directories are expanded by the caller.
        let paths: [String]
    }

    let project: PBXProjectObjects
    private var objects: [String: [String: Any]] { project.objects }

    init(project: PBXProjectObjects) { self.project = project }

    func appTargets() -> [AppTarget] {
        var out: [AppTarget] = []
        for (targetId, object) in objects where object["isa"] as? String == "PBXNativeTarget" {
            guard (object["productType"] as? String)?.hasPrefix("com.apple.product-type.application") == true else { continue }
            let phases = (object["buildPhases"] as? [String] ?? []).filter {
                objects[$0]?["isa"] as? String == "PBXSourcesBuildPhase"
            }
            var paths: [String] = []
            for phase in phases {
                for buildFile in objects[phase]?["files"] as? [String] ?? [] {
                    if let ref = objects[buildFile]?["fileRef"] as? String, let path = project.absolutePath(of: ref) {
                        paths.append(path)
                    }
                }
            }
            for group in object["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                guard let path = project.absolutePath(of: group) else { continue }
                let excluded = exceptions(in: group, targetId: targetId, phases: phases)
                for entry in FileTreeWalker(root: path) where entry.path.hasSuffix(".swift") {
                    let relative = String(entry.path.dropFirst(path.count + 1))
                    if !excluded.contains(relative) { paths.append(entry.path) }
                }
            }
            out.append(AppTarget(
                name: object["name"] as? String ?? targetId, platforms: platforms(of: object), paths: paths
            ))
        }
        return out.sorted { $0.name < $1.name }
    }

    private func exceptions(in groupId: String, targetId: String, phases: [String]) -> Set<String> {
        var excluded: Set<String> = []
        for setId in objects[groupId]?["exceptions"] as? [String] ?? [] {
            guard let set = objects[setId] else { continue }
            let members = Set(set["membershipExceptions"] as? [String] ?? [])
            switch set["isa"] as? String {
            case "PBXFileSystemSynchronizedBuildFileExceptionSet":
                if set["target"] as? String == targetId { excluded.formUnion(members) }
            case "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet":
                if let phase = set["buildPhase"] as? String, phases.contains(phase) { excluded.formUnion(members) }
            default:
                continue
            }
        }
        return excluded
    }

    /// Union across configurations of the platforms the target builds for; empty when unknown.
    private func platforms(of target: [String: Any]) -> [String] {
        let project = settings(of: objects.values.first { $0["isa"] as? String == "PBXProject" }?["buildConfigurationList"] as? String)
        let own = settings(of: target["buildConfigurationList"] as? String)
        var found: [String] = []
        for (config, targetSettings) in own {
            let merged = (project[config] ?? [:]).merging(targetSettings) { _, new in new }
            let sdk = merged["SDKROOT"] ?? "auto"
            let tokens = sdk == "auto" ? (merged["SUPPORTED_PLATFORMS"] ?? "").split(separator: " ").map(String.init) : [sdk]
            for token in tokens {
                let platform: String?
                switch token {
                case "iphoneos", "iphonesimulator": platform = "iOS"
                case "macosx": platform = "macOS"
                case "watchos", "watchsimulator": platform = "watchOS"
                case "appletvos", "appletvsimulator": platform = "tvOS"
                case "xros", "xrsimulator": platform = "visionOS"
                default: platform = nil
                }
                if let platform, !found.contains(platform) { found.append(platform) }
            }
        }
        return found.sorted()
    }

    private func settings(of listId: String?) -> [String: [String: String]] {
        guard let listId, let list = objects[listId] else { return [:] }
        var out: [String: [String: String]] = [:]
        for configId in list["buildConfigurations"] as? [String] ?? [] {
            guard let config = objects[configId], let name = config["name"] as? String else { continue }
            var flat: [String: String] = [:]
            for (key, value) in config["buildSettings"] as? [String: Any] ?? [:] {
                if let string = value as? String { flat[key] = string }
                else if let array = value as? [String] { flat[key] = array.joined(separator: " ") }
            }
            out[name] = flat
        }
        return out
    }
}
