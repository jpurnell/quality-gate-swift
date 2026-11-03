import Foundation
import QualityGateCore
import QualityGateLogging

/// Which Apple platforms an Xcode project builds each source file for.
///
/// A SwiftUI file says nothing about its platform: `import SwiftUI` is the same text in a
/// watch app, a tvOS app and a Mac app. The answer is in the project — the `SDKROOT` or
/// `SUPPORTED_PLATFORMS` of the targets whose Sources phase compiles the file — so that is
/// where it is read from, rather than guessed from names or from the marker imports a file
/// happens to carry. See `AWatchAppIsNotAMacApp.md`.
///
/// Resolution is conservative by construction: a file that no parsed target compiles, or that
/// belongs to a target whose platform cannot be determined, resolves to `nil`, and the caller
/// falls back to what it did before this type existed. A guess here would turn a missing
/// rule into a wrong one.
struct XcodeProjectPlatforms: Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "XcodeProjectPlatforms")

    /// A set of files compiled by one target, and the platforms that target builds for.
    struct Membership: Sendable {
        /// Absolute, standardized path of the file, or of the directory when ``isDirectory``.
        let path: String
        let isDirectory: Bool
        /// Paths under a synchronized folder that the target does not compile, relative to it.
        let excluded: Set<String>
        /// `nil` when the target's platform could not be determined.
        let platforms: HIGPlatform?
    }

    private var memberships: [Membership] = []

    /// Projects parsed, and `.xcodeproj` bundles that could not be read.
    private(set) var projectCount = 0
    private(set) var unreadableProjectCount = 0

    /// True when no project was found, so callers can skip the per-file lookup entirely.
    var isEmpty: Bool { memberships.isEmpty }

    // MARK: - Lookup

    /// The platforms every target compiling `file` builds for, or `nil` when unknown.
    ///
    /// The union across targets: a view shared by a watch target and a Mac target is audited
    /// for both. If any containing target's platform is unknown the answer is `nil` — a partial
    /// union would silently drop the unknown target's rules.
    func platforms(forFile file: String) -> HIGPlatform? {
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        var union: HIGPlatform = []
        var matched = false
        for membership in memberships {
            guard Self.contains(membership, path: path) else { continue }
            guard let platforms = membership.platforms else { return nil }
            union.formUnion(platforms)
            matched = true
        }
        return matched && !union.isEmpty ? union : nil
    }

    private static func contains(_ membership: Membership, path: String) -> Bool {
        guard membership.isDirectory else { return membership.path == path }
        let prefix = membership.path.hasSuffix("/") ? membership.path : membership.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        return !membership.excluded.contains(String(path.dropFirst(prefix.count)))
    }

    // MARK: - Discovery

    /// Directories never searched for projects: build output and vendored checkouts.
    private static let skippedDirectories: Set<String> = [
        ".build", ".git", ".swiftpm", "DerivedData", "Pods", "Carthage", "checkouts", "node_modules",
    ]

    /// Parses every `*.xcodeproj` under `root`.
    ///
    /// Membership is keyed by absolute path rather than by "nearest ancestor project", because
    /// a project may compile sources through `..` and a file's nearest `.xcodeproj` is then
    /// not the one that builds it.
    static func discover(under root: URL) -> XcodeProjectPlatforms {
        var result = XcodeProjectPlatforms()
        let walker = FileTreeWalker(root: root, options: [.skipsHiddenFiles])

        for entry in walker {
            guard entry.isDirectory else { continue }
            if skippedDirectories.contains(entry.name) {
                walker.skipDescendants()
                continue
            }
            guard entry.url.pathExtension == "xcodeproj" else { continue }
            walker.skipDescendants()
            let url = entry.url
            let pbxproj = url.appendingPathComponent("project.pbxproj")
            if let parsed = parse(pbxproj: pbxproj) {
                result.memberships.append(contentsOf: parsed)
                result.projectCount += 1
            } else {
                result.unreadableProjectCount += 1
            }
        }
        return result
    }

    /// Builds the membership list for one project file, or `nil` when it is not readable.
    static func parse(pbxproj: URL) -> [Membership]? {
        let data: Data
        do {
            data = try Data(contentsOf: pbxproj)
        } catch {
            logger.warning("Could not read \(pbxproj.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            logger.warning("Could not parse \(pbxproj.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let top = plist as? [String: Any], let objects = top["objects"] as? [String: [String: Any]] else {
            logger.warning("No object table in \(pbxproj.path, privacy: .public)")
            return nil
        }
        let projectDir = pbxproj.deletingLastPathComponent().deletingLastPathComponent()
        return Builder(objects: objects, projectDir: projectDir).memberships()
    }

    // MARK: - Pbxproj reading

    /// Walks the object table of a single parsed project.
    private struct Builder {
        let objects: [String: [String: Any]]
        let projectDir: URL

        /// Parent group of each group/file id, from every group's `children`.
        private let parents: [String: String]

        init(objects: [String: [String: Any]], projectDir: URL) {
            self.objects = objects
            self.projectDir = projectDir
            var parents: [String: String] = [:]
            for (id, object) in objects {
                for child in object["children"] as? [String] ?? [] { parents[child] = id }
            }
            self.parents = parents
        }

        func memberships() -> [Membership] {
            var out: [Membership] = []
            for (targetId, object) in objects where object["isa"] as? String == "PBXNativeTarget" {
                guard Self.buildsSources(productType: object["productType"] as? String) else { continue }
                let platforms = targetPlatforms(object)
                let sourcesPhases = sourcesPhaseIds(of: object)

                for phaseId in sourcesPhases {
                    for buildFileId in objects[phaseId]?["files"] as? [String] ?? [] {
                        guard let fileRef = objects[buildFileId]?["fileRef"] as? String,
                              let path = absolutePath(of: fileRef) else { continue }
                        out.append(Membership(path: path, isDirectory: false, excluded: [], platforms: platforms))
                    }
                }

                for groupId in object["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                    guard let path = absolutePath(of: groupId) else { continue }
                    let excluded = exceptions(in: groupId, targetId: targetId, sourcesPhases: sourcesPhases)
                    out.append(Membership(path: path, isDirectory: true, excluded: excluded, platforms: platforms))
                }
            }
            return out
        }

        /// Test bundles compile test sources, not the app's, and would add their own platform.
        private static func buildsSources(productType: String?) -> Bool {
            guard let productType else { return true }
            return !productType.contains("unit-test") && !productType.contains("ui-testing")
        }

        private func sourcesPhaseIds(of target: [String: Any]) -> [String] {
            (target["buildPhases"] as? [String] ?? []).filter {
                objects[$0]?["isa"] as? String == "PBXSourcesBuildPhase"
            }
        }

        /// Files a synchronized folder holds that this target does *not* compile.
        private func exceptions(in groupId: String, targetId: String, sourcesPhases: [String]) -> Set<String> {
            var excluded: Set<String> = []
            for setId in objects[groupId]?["exceptions"] as? [String] ?? [] {
                guard let set = objects[setId] else { continue }
                let members = Set(set["membershipExceptions"] as? [String] ?? [])
                switch set["isa"] as? String {
                case "PBXFileSystemSynchronizedBuildFileExceptionSet":
                    if set["target"] as? String == targetId { excluded.formUnion(members) }
                case "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet":
                    if let phase = set["buildPhase"] as? String, sourcesPhases.contains(phase) {
                        excluded.formUnion(members)
                    }
                default:
                    continue
                }
            }
            return excluded
        }

        /// Absolute path of a file reference or group, following `path` up the group chain.
        private func absolutePath(of id: String) -> String? {
            var components: [String] = []
            var current: String? = id
            var base = projectDir
            var visited: Set<String> = []
            while let node = current, let object = objects[node], visited.insert(node).inserted {
                let path = object["path"] as? String ?? ""
                switch object["sourceTree"] as? String {
                case "SOURCE_ROOT":
                    components.append(path)
                    current = nil
                case "<absolute>":
                    components.append(path)
                    base = URL(fileURLWithPath: "/")
                    current = nil
                case "<group>":
                    components.append(path)
                    current = parents[node]
                default:
                    return nil
                }
            }
            // `visited` cuts a cycle; a group chain that ends anywhere but the project root is fine.
            let relative = components.reversed().filter { !$0.isEmpty }
            let url = relative.reduce(base) { $0.appendingPathComponent($1) }
            return url.standardizedFileURL.path
        }

        // MARK: Build settings

        /// The union, across build configurations, of what the target builds for; `nil` if unknown.
        private func targetPlatforms(_ target: [String: Any]) -> HIGPlatform? {
            let projectSettings = settingsByConfiguration(projectConfigurationList())
            let targetSettings = settingsByConfiguration(target["buildConfigurationList"] as? String)
            var union: HIGPlatform = []
            for (name, own) in targetSettings {
                let merged = (projectSettings[name] ?? [:]).merging(own) { _, target in target }
                guard let platforms = HIGPlatform.resolve(buildSettings: merged) else { return nil }
                union.formUnion(platforms)
            }
            return union.isEmpty ? nil : union
        }

        private func projectConfigurationList() -> String? {
            objects.values.first { $0["isa"] as? String == "PBXProject" }?["buildConfigurationList"] as? String
        }

        private func settingsByConfiguration(_ listId: String?) -> [String: [String: String]] {
            guard let listId, let list = objects[listId] else { return [:] }
            var out: [String: [String: String]] = [:]
            for configId in list["buildConfigurations"] as? [String] ?? [] {
                guard let config = objects[configId], let name = config["name"] as? String else { continue }
                var flat: [String: String] = [:]
                for (key, value) in config["buildSettings"] as? [String: Any] ?? [:] {
                    if let string = value as? String {
                        flat[key] = string
                    } else if let array = value as? [String] {
                        flat[key] = array.joined(separator: " ")
                    }
                }
                out[name] = flat
            }
            return out
        }
    }
}

extension HIGPlatform {

    /// The platforms a target builds for, read from its resolved build settings.
    ///
    /// `SUPPORTED_PLATFORMS` wins over `SDKROOT`: a multiplatform target says `SDKROOT = auto`
    /// and lists the SDKs it builds. `TARGETED_DEVICE_FAMILY` then narrows an iOS-family
    /// target, and Mac Catalyst adds macOS. Returns `nil` for anything this cannot resolve —
    /// an unset or `auto` SDK with no platform list, or a setting still holding a `$(VARIABLE)`.
    static func resolve(buildSettings settings: [String: String]) -> HIGPlatform? {
        let tokens: [String]
        if let supported = settings["SUPPORTED_PLATFORMS"] {
            tokens = supported.split(separator: " ").map(String.init)
        } else if let sdk = settings["SDKROOT"] {
            tokens = [sdk]
        } else {
            return nil
        }
        guard !tokens.contains(where: { $0.contains("$") }) else { return nil }

        var platforms: HIGPlatform = []
        for token in tokens {
            // A versioned SDK path ("iphoneos17.0") names the same platform as its stem.
            let sdk = String(token.prefix { !$0.isNumber })
            switch sdk {
            case "macosx":
                platforms.insert(.macOS)
            case "iphoneos", "iphonesimulator":
                platforms.formUnion(iOSFamily(settings["TARGETED_DEVICE_FAMILY"]))
                if settings["SUPPORTS_MACCATALYST"] == "YES" { platforms.insert(.macOS) }
            case "watchos", "watchsimulator":
                platforms.insert(.watchOS)
            case "appletvos", "appletvsimulator":
                platforms.insert(.tvOS)
            case "xros", "xrsimulator":
                platforms.insert(.visionOS)
            default:
                continue
            }
        }
        return platforms.isEmpty ? nil : platforms
    }

    /// iPhone and iPad membership from `TARGETED_DEVICE_FAMILY`; an unset family is both.
    private static func iOSFamily(_ family: String?) -> HIGPlatform {
        guard let family else { return [.iOS, .iPadOS] }
        let codes = Set(family.split { $0 == "," || $0 == " " }.map(String.init))
        var out: HIGPlatform = []
        if codes.contains("1") { out.insert(.iOS) }
        if codes.contains("2") { out.insert(.iPadOS) }
        return out
    }
}
