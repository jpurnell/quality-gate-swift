import Foundation

/// Recursively enumerates `.swift` files under a project root, skipping
/// build outputs, dependency directories, and Xcode container packages.
///
/// Replaces the previous `Sources/`-only walk so the auditor works on
/// any Swift codebase layout (Xcode app projects, ad-hoc directories,
/// SwiftPM packages with non-conventional source paths, etc.).
enum SourceWalker {

    /// Directory names that are never walked. `.skipsHiddenFiles` already
    /// covers `.git`, `.build`, `.swiftpm`, etc.; this set covers the
    /// non-hidden output / dependency directories that are conventionally
    /// ignored.
    static let defaultSkipDirectories: Set<String> = [
        // hidden ones too, in case .skipsHiddenFiles is bypassed by a caller
        ".git", ".build", ".swiftpm", ".bundle",
        // non-hidden output / dependency dirs
        "DerivedData", "build", "Build", "Pods", "Carthage", "node_modules",
    ]

    /// Returns absolute paths of every `.swift` file under `root`,
    /// skipping the default-skip set, `*.xcodeproj` / `*.xcworkspace`
    /// containers, and anything matching `excludePatterns`.
    static func swiftFiles(under root: URL, excludePatterns: [String] = []) -> [String] {
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
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
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
