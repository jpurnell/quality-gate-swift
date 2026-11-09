import Foundation
import QualityGateCore

/// Finds every `.skillsbundle` under a root and judges it.
///
/// The structural rules are Apple's constraints on a bundle, and each one guards a silent
/// failure: a bundle that breaks one is not refused at build time, it is just not offered to
/// Siri. See `OneReadinessManyCarriers.md` §4.5.
enum SkillsAudit {

    /// The most characters a skill body may hold.
    static let maxBodyCharacters = 10_000

    private static let allowedKeys: Set<String> = ["name", "description"]
    private static let folderPattern = #"^[a-z0-9-]+$"#
    private static let typeNamePattern = #"\b[A-Z][A-Za-z0-9]*(?:Intent|Entity)\b"#
    private static let skippedDirectories: Set<String> = [
        ".build", ".git", ".swiftpm", "DerivedData", "Pods", "Carthage", "checkouts", "node_modules",
    ]

    /// Every `.skillsbundle` under `root`, as absolute paths in a stable order.
    static func bundles(under root: URL) -> [URL] {
        var found: [URL] = []
        let walker = FileTreeWalker(root: root, options: [.skipsHiddenFiles])
        for entry in walker {
            guard entry.isDirectory else { continue }
            if skippedDirectories.contains(entry.name) {
                walker.skipDescendants()
                continue
            }
            if entry.url.pathExtension == "skillsbundle" {
                found.append(entry.url)
                walker.skipDescendants()
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    static func analyze(root: URL) -> [Diagnostic] {
        let urls = bundles(under: root)
        guard !urls.isEmpty else { return [] }
        let bundles = urls.map { SkillBundle.read(at: $0) }

        var out: [Diagnostic] = []
        for bundle in bundles { out += structure(of: bundle) }
        out += duplicateNames(in: bundles)
        out += membership(of: bundles, root: root)
        return out
    }

    // MARK: Per-bundle rules

    private static func structure(of bundle: SkillBundle) -> [Diagnostic] {
        var out: [Diagnostic] = []
        for skill in bundle.skills {
            if skill.folder.range(of: folderPattern, options: .regularExpression) == nil {
                out.append(error(skill.path, "skills.bad-folder-name",
                    "Skill folder '\(skill.folder)' is not lowercase letters, digits and hyphens, so Siri will not load it.",
                    fix: "Rename the folder to match [a-z0-9-]+, for example '\(suggestedName(skill.folder))'."))
            }
            guard let text = skill.text else {
                out.append(error(skill.path, "skills.missing-skill-md",
                    "Skill folder '\(skill.folder)' has no SKILL.md.", fix: "Add a SKILL.md with name and description frontmatter."))
                continue
            }
            let extras = skill.entries.filter { $0 != "SKILL.md" }
            if !extras.isEmpty {
                out.append(error(skill.path, "skills.extra-files",
                    "Skill folder '\(skill.folder)' holds more than SKILL.md: \(extras.joined(separator: ", ")).",
                    fix: "A skill folder holds exactly one SKILL.md. Move anything else out."))
            }
            out += document(SkillDocument(text), at: skill)
        }
        return out
    }

    private static func document(_ document: SkillDocument, at skill: Skill) -> [Diagnostic] {
        var out: [Diagnostic] = []
        let file = skill.skillMdPath
        if !document.hasFrontmatter {
            out.append(error(file, "skills.frontmatter-fields",
                "SKILL.md in '\(skill.folder)' has no frontmatter; it needs name and description.",
                fix: "Begin the file with --- name: ... description: ... ---."))
        } else {
            for key in document.keys where !allowedKeys.contains(key) {
                out.append(error(file, "skills.frontmatter-fields",
                    "SKILL.md in '\(skill.folder)' has frontmatter key '\(key)'; only name and description are allowed.",
                    fix: "Remove '\(key)'."))
            }
            for required in ["name", "description"] where !(document.keys.contains(required)) {
                out.append(error(file, "skills.frontmatter-fields",
                    "SKILL.md in '\(skill.folder)' is missing '\(required)'.", fix: "Add a '\(required):' line."))
            }
        }
        if document.body.count > maxBodyCharacters {
            out.append(error(file, "skills.body-too-long",
                "SKILL.md in '\(skill.folder)' has a \(document.body.count)-character body; the limit is \(maxBodyCharacters).",
                fix: "Shorten it. A skill is guidance a tool description cannot carry, not a manual."))
        }
        let typeNames = typeNames(in: document.body)
        if !typeNames.isEmpty {
            out.append(Diagnostic(
                severity: .note,
                message: "SKILL.md in '\(skill.folder)' names \(typeNames.joined(separator: ", ")). Apple's guidance is to describe what the action does, not to name the type.",
                filePath: file, lineNumber: 1, columnNumber: 1, ruleId: "skills.names-type",
                suggestedFix: "Say what the action does in plain words."))
        }
        return out
    }

    private static func typeNames(in body: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: typeNamePattern) else { return [] } // silent: a constant pattern; failing to compile reads as no matches
        let range = NSRange(body.startIndex..., in: body)
        var seen: [String] = []
        for match in expression.matches(in: body, range: range) {
            guard let r = Range(match.range, in: body) else { continue }
            let name = String(body[r])
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private static func suggestedName(_ folder: String) -> String {
        var out = ""
        for character in folder {
            if character.isUppercase, !out.isEmpty, out.last != "-" { out.append("-") }
            out.append(contentsOf: character.lowercased())
        }
        return String(out.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }

    // MARK: Project rules

    private static func duplicateNames(in bundles: [SkillBundle]) -> [Diagnostic] {
        var firstSeen: [String: String] = [:]
        var out: [Diagnostic] = []
        for bundle in bundles {
            for skill in bundle.skills {
                guard let text = skill.text, let name = SkillDocument(text).name, !name.isEmpty else { continue }
                if let earlier = firstSeen[name] {
                    out.append(error(skill.skillMdPath, "skills.duplicate-name",
                        "Skill name '\(name)' is already used by \(earlier).",
                        fix: "Skill names must be unique across the app, its extensions and embedded frameworks."))
                } else {
                    firstSeen[name] = skill.skillMdPath
                }
            }
        }
        return out
    }

    private static func membership(of bundles: [SkillBundle], root: URL) -> [Diagnostic] {
        let membership = BundleMembership.discover(under: root)
        guard membership.isConclusive else { return [] }
        var out: [Diagnostic] = []
        let bundlePaths = bundles.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        for (bundle, path) in zip(bundles, bundlePaths) where !membership.targets.contains(where: { $0.includes(path) }) {
            out.append(error(bundle.path, "skills.bundle-not-in-target",
                "\(bundle.name) is not in any target's Copy Bundle Resources, so it is absent from the built app and Siri never sees its skills.",
                fix: "Add the bundle to the app target's Copy Bundle Resources phase."))
        }
        for target in membership.targets {
            let held = zip(bundles, bundlePaths).filter { target.includes($0.1) }.map(\.0)
            guard held.count > 1 else { continue }
            for extra in held.dropFirst() {
                out.append(error(extra.path, "skills.multiple-bundles",
                    "Target '\(target.name)' copies \(held.count) skills bundles (\(held.map(\.name).joined(separator: ", "))); a target may have one.",
                    fix: "Merge the skill folders into one bundle."))
            }
        }
        return out
    }

    private static func error(_ path: String, _ rule: String, _ message: String, fix: String) -> Diagnostic {
        Diagnostic(
            severity: .error, message: message, filePath: path, lineNumber: 1, columnNumber: 1,
            ruleId: rule, suggestedFix: fix)
    }
}
