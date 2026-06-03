import Foundation

/// Recursively enumerates `.swift` files under a project root, skipping
/// build outputs, dependency directories, and Xcode container packages.
public enum SourceWalker {

    static let defaultSkipDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".bundle",
        "DerivedData", "build", "Build", "Pods", "Carthage", "node_modules",
    ]

    /// Returns absolute paths of every `.swift` file under `root`,
    /// skipping the default-skip set, `*.xcodeproj` / `*.xcworkspace`
    /// containers, and anything matching `excludePatterns`.
    public static func swiftFiles(under root: URL, excludePatterns: [String] = []) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }

        var out: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false // silent: treats unreadable entries as files
            if isDirectory {
                if defaultSkipDirectories.contains(name)
                    || name.hasSuffix(".xcodeproj")
                    || name.hasSuffix(".xcworkspace") {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            let path = url.path
            if shouldExclude(path: path, patterns: excludePatterns) { continue }
            out.append(path)
        }
        return out
    }

    private static func shouldExclude(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            let stripped = pattern
                .replacingOccurrences(of: "**/", with: "")
                .replacingOccurrences(of: "/**", with: "")
                .replacingOccurrences(of: "*", with: "")
            if !stripped.isEmpty, path.contains(stripped) { return true }
        }
        return false
    }
}
