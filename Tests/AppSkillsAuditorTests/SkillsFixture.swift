import Foundation

/// A throwaway project directory: skill bundles on disk and, optionally, an Xcode project
/// naming which of them each target copies.
struct SkillsFixture {
    let root: URL

    /// One target and the resources its Copy Bundle Resources phase lists (paths from the root).
    struct Target {
        var name: String
        var resources: [String] = []
        /// A synchronized folder the target owns, and what it excludes from the Resources phase.
        var synchronizedFolder: String?
        var exceptions: [String] = []
    }

    init(files: [String: String] = [:], directories: [String] = [], targets: [Target]? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for (relative, text) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        if let targets {
            let proj = root.appendingPathComponent("App.xcodeproj")
            try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
            try Self.render(targets).write(
                to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) } // silent: temp-dir cleanup in a test

    /// A skill's `SKILL.md`.
    static func skill(name: String, description: String = "Adds a flight to the trip", extra: String = "", body: String = "Search first, then add.") -> String {
        "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\n\(body)\n"
    }

    private static func q(_ s: String) -> String { "\"" + s + "\"" }

    private static func render(_ targets: [Target]) -> String {
        var objects: [String] = []
        var children: [String] = []
        objects.append("PROJCFG = { isa = XCBuildConfiguration; name = Debug; buildSettings = { }; };")
        objects.append("PROJLIST = { isa = XCConfigurationList; buildConfigurations = (PROJCFG); };")
        objects.append("PROJECT = { isa = PBXProject; buildConfigurationList = PROJLIST; mainGroup = MAIN; targets = (\(targets.indices.map { "T\($0)" }.joined(separator: ", "))); };")
        var refs: [String: String] = [:]
        for (i, target) in targets.enumerated() {
            var buildFiles: [String] = []
            for resource in target.resources {
                let ref = refs[resource] ?? "REF\(refs.count)"
                if refs[resource] == nil {
                    refs[resource] = ref
                    objects.append("\(ref) = { isa = PBXFileReference; lastKnownFileType = folder; path = \(q(resource)); sourceTree = SOURCE_ROOT; };")
                    children.append(ref)
                }
                objects.append("T\(i)BF\(buildFiles.count) = { isa = PBXBuildFile; fileRef = \(ref); };")
                buildFiles.append("T\(i)BF\(buildFiles.count)")
            }
            objects.append("T\(i)RES = { isa = PBXResourcesBuildPhase; files = (\(buildFiles.joined(separator: ", "))); };")
            var extra = ""
            if let folder = target.synchronizedFolder {
                objects.append("SYNC\(i) = { isa = PBXFileSystemSynchronizedRootGroup; path = \(q(folder)); sourceTree = \"<group>\"; exceptions = (EXC\(i)); };")
                objects.append("EXC\(i) = { isa = PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet; buildPhase = T\(i)RES; membershipExceptions = (\(target.exceptions.map(q).joined(separator: ", "))); };")
                children.append("SYNC\(i)")
                extra = "fileSystemSynchronizedGroups = (SYNC\(i));"
            }
            objects.append("T\(i) = { isa = PBXNativeTarget; name = \(q(target.name)); productType = \"com.apple.product-type.application\"; buildPhases = (T\(i)RES); \(extra) };")
        }
        objects.append("MAIN = { isa = PBXGroup; sourceTree = \"<group>\"; children = (\(children.joined(separator: ", "))); };")
        return "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; rootObject = PROJECT; objects = {\n"
            + objects.joined(separator: "\n") + "\n}; }\n"
    }
}
