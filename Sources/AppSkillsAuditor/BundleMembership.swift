import Foundation
import QualityGateCore

/// Which Xcode targets copy which resources, read from every project under a root.
///
/// An Apple skills bundle that is on disk but not in the target's Copy Bundle Resources phase
/// is not rejected anywhere: it is absent from the built app, and Siri never sees it. So
/// membership is what turns "the files are right" into "the feature works".
struct BundleMembership {

    /// What one target copies: files and folders named in its Resources phase, and the
    /// synchronized folders that supply resources implicitly.
    struct TargetResources {
        let name: String
        /// Absolute paths named by the Resources phase.
        let listed: Set<String>
        /// Synchronized folders: absolute path and what the Resources phase excludes from it.
        let synchronized: [(path: String, excluded: Set<String>)]

        func includes(_ path: String) -> Bool {
            if listed.contains(path) { return true }
            for folder in synchronized {
                let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
                guard path.hasPrefix(prefix) else { continue }
                if !folder.excluded.contains(String(path.dropFirst(prefix.count))) { return true }
            }
            return false
        }
    }

    private(set) var targets: [TargetResources] = []
    private(set) var projectCount = 0
    private(set) var unreadableProjectCount = 0

    /// Membership can be judged only when a project was read and none was unreadable: a bundle
    /// might be in the one that could not be parsed.
    var isConclusive: Bool { projectCount > 0 && unreadableProjectCount == 0 }

    private static let skippedDirectories: Set<String> = [
        ".build", ".git", ".swiftpm", "DerivedData", "Pods", "Carthage", "checkouts", "node_modules",
    ]

    static func discover(under root: URL) -> BundleMembership {
        var result = BundleMembership()
        let walker = FileTreeWalker(root: root, options: [.skipsHiddenFiles])
        for entry in walker {
            guard entry.isDirectory else { continue }
            if skippedDirectories.contains(entry.name) {
                walker.skipDescendants()
                continue
            }
            guard entry.url.pathExtension == "xcodeproj" else { continue }
            walker.skipDescendants()
            let pbxproj = entry.url.appendingPathComponent("project.pbxproj")
            if let project = PBXProjectObjects.load(pbxproj: pbxproj) {
                result.targets.append(contentsOf: targets(in: project))
                result.projectCount += 1
            } else {
                result.unreadableProjectCount += 1
            }
        }
        return result
    }

    private static func targets(in project: PBXProjectObjects) -> [TargetResources] {
        let objects = project.objects
        var out: [TargetResources] = []
        for (targetId, object) in objects where object["isa"] as? String == "PBXNativeTarget" {
            let phases = (object["buildPhases"] as? [String] ?? []).filter {
                objects[$0]?["isa"] as? String == "PBXResourcesBuildPhase"
            }
            var listed: Set<String> = []
            for phase in phases {
                for buildFile in objects[phase]?["files"] as? [String] ?? [] {
                    if let ref = objects[buildFile]?["fileRef"] as? String, let path = project.absolutePath(of: ref) {
                        listed.insert(path)
                    }
                }
            }
            var synchronized: [(path: String, excluded: Set<String>)] = []
            for group in object["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                guard let path = project.absolutePath(of: group) else { continue }
                synchronized.append((path, exceptions(in: group, targetId: targetId, phases: phases, objects: objects)))
            }
            out.append(TargetResources(
                name: object["name"] as? String ?? targetId, listed: listed, synchronized: synchronized))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// What a synchronized folder holds that this target does not copy as a resource.
    private static func exceptions(
        in group: String, targetId: String, phases: [String], objects: [String: [String: Any]]
    ) -> Set<String> {
        var excluded: Set<String> = []
        for setId in objects[group]?["exceptions"] as? [String] ?? [] {
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
}
