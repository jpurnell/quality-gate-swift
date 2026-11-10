import Foundation
import QualityGateCore

/// The files under a project root that `design-token-drift` may read, as project-relative paths.
///
/// Built from one walk. Build products, dependency checkouts and hidden directories are never
/// entered. Nothing else is skipped implicitly: a package, a palette or a test directory is exempt
/// only because `.quality-gate.yml` lists it.
struct ProjectFiles: Sendable {
    let root: URL
    /// Every regular file, sorted, as project-relative paths with `/` separators.
    let relativePaths: [String]

    private static let skippedDirectories: Set<String> = [
        ".build", ".git", ".swiftpm", "DerivedData", "Pods", "Carthage", "checkouts", "node_modules", "build",
    ]
    private static let skippedSuffixes = [".xcodeproj", ".xcworkspace"]

    init(root: URL, excludePatterns: [String]) {
        self.root = root
        var found: [String] = []
        let walker = FileTreeWalker(root: root, options: [.skipsHiddenFiles])
        for entry in walker {
            if entry.isDirectory {
                if Self.skippedDirectories.contains(entry.name)
                    || Self.skippedSuffixes.contains(where: { entry.name.hasSuffix($0) }) {
                    walker.skipDescendants()
                }
                continue
            }
            guard entry.isRegularFile else { continue }
            if excludePatterns.contains(where: { PathGlob.matches($0, path: entry.relativePath) }) { continue }
            found.append(entry.relativePath)
        }
        relativePaths = found.sorted()
    }

    /// The absolute path of a project-relative one.
    func absolutePath(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    /// Files whose path matches any of `patterns`.
    func matching(_ patterns: [String]) -> [String] {
        relativePaths.filter { path in patterns.contains { PathGlob.matches($0, path: path) } }
    }

    func isSwift(_ path: String) -> Bool { path.hasSuffix(".swift") }

    func isCSS(_ path: String) -> Bool { path.lowercased().hasSuffix(".css") }

    func isHTML(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasSuffix(".html") || lowered.hasSuffix(".htm")
    }
}
