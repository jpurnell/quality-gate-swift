import Foundation
import QualityGateLogging

/// The object table of one Xcode project file, with the path resolution every reader of it needs.
///
/// A `project.pbxproj` is a property list whose `objects` map an id to a record. Which target
/// compiles a source file, which target copies a resource, and what a target builds for are all
/// questions asked of that table, and each begins the same way: find the record, then follow
/// `path` up the group chain to an absolute location. This type is that shared beginning, so
/// the readers (`HIGAuditor`'s platform resolution, `AppSkillsAuditor`'s bundle membership) do
/// not each carry a copy of it.
///
/// It reads and resolves; it does not interpret. What a build phase means is the caller's.
public struct PBXProjectObjects {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "PBXProjectObjects")

    /// Every record in the project, keyed by id.
    public let objects: [String: [String: Any]]

    /// The directory containing the `.xcodeproj`, which `SOURCE_ROOT` paths are relative to.
    public let projectDir: URL

    /// Parent group of each group or file id, from every group's `children`.
    private let parents: [String: String]

    /// Wraps an already-parsed object table.
    public init(objects: [String: [String: Any]], projectDir: URL) {
        self.objects = objects
        self.projectDir = projectDir
        var parents: [String: String] = [:]
        for (id, object) in objects {
            for child in object["children"] as? [String] ?? [] { parents[child] = id }
        }
        self.parents = parents
    }

    /// Parses a `project.pbxproj`, or returns `nil` (after logging why) when it is unreadable.
    public static func load(pbxproj: URL) -> PBXProjectObjects? {
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
        return PBXProjectObjects(objects: objects, projectDir: projectDir)
    }

    /// Absolute path of a file reference or group, following `path` up the group chain.
    ///
    /// `nil` when a node uses a source tree this cannot resolve (`BUILT_PRODUCTS_DIR`, an SDK
    /// root), so a caller treats the location as unknown rather than guessing it.
    public func absolutePath(of id: String) -> String? {
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
}
