import Foundation
import QualityGateCore

/// One skill folder inside a `.skillsbundle`, as found on disk.
struct Skill {
    /// The folder name.
    let folder: String
    /// Absolute path of the folder.
    let path: String
    /// Entries in the folder other than a tolerated `.DS_Store`, files and directories alike.
    let entries: [String]
    /// The text of `SKILL.md`, or `nil` when there is none.
    let text: String?

    var skillMdPath: String { path + "/SKILL.md" }
}

/// A `.skillsbundle` directory and the skill folders it holds.
struct SkillBundle {
    /// Absolute path of the bundle directory.
    let path: String
    let skills: [Skill]

    var name: String { (path as NSString).lastPathComponent }

    /// Reads one bundle. A skill folder is any directory directly inside it.
    static func read(at url: URL) -> SkillBundle {
        let fileManager = FileManager.default
        let children = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [] // silent: an unreadable bundle has no skills, which the rules then report
        var skills: [Skill] = []
        let bundleComponents = url.resolvingSymlinksInPath().pathComponents
        for child in children.sorted() where !child.hasPrefix(".") {
            let folder = url.appendingPathComponent(child)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            // A folder that resolves outside the bundle (a symlink) is not read: it is reported
            // as holding no SKILL.md rather than followed out of the tree being checked.
            guard folder.resolvingSymlinksInPath().pathComponents.starts(with: bundleComponents) else {
                skills.append(Skill(folder: child, path: folder.path, entries: [], text: nil))
                continue
            }
            let entries = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []) // silent: an unreadable folder reads as empty and is reported as missing SKILL.md
                .filter { $0 != ".DS_Store" }
                .sorted()
            let skillMd = folder.appendingPathComponent("SKILL.md")
            let text = entries.contains("SKILL.md")
                ? (try? String(contentsOf: skillMd, encoding: .utf8)) // silent: unreadable reads as missing, reported by skills.missing-skill-md
                : nil
            skills.append(Skill(folder: child, path: folder.path, entries: entries, text: text))
        }
        return SkillBundle(path: url.path, skills: skills)
    }
}

/// A `SKILL.md` split into its frontmatter keys and its body.
struct SkillDocument {
    /// Top-level keys of the frontmatter, in order; empty when there is none.
    let keys: [String]
    /// Values of `name` and `description`, when present.
    let name: String?
    let description: String?
    let hasFrontmatter: Bool
    let body: String

    init(_ text: String) {
        let lines = text.lines
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            keys = []
            name = nil
            description = nil
            hasFrontmatter = false
            body = text
            return
        }
        var keys: [String] = []
        var values: [String: String] = [:]
        for line in lines[1..<close] {
            // A key starts in the first column; an indented line continues the previous value.
            guard let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            keys.append(key)
            values[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.keys = keys
        name = values["name"]
        description = values["description"]
        hasFrontmatter = true
        body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
