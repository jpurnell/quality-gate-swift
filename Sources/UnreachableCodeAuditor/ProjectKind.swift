import Foundation

/// What kind of Swift project lives at a given root directory.
///
/// Detection drives both source enumeration and index-store location:
///
/// - `.swiftPM` — auto-build with `swift build -Xswiftc -index-store-path …`,
///   walk `Sources/` (and any other top-level dirs containing `.swift`).
/// - `.xcode` — locate an existing index store under
///   `~/Library/Developer/Xcode/DerivedData/`. No auto-build.
/// - `.plain` — syntactic pass only; cross-module is skipped with a `.note`.
enum ProjectKind: Sendable {
    case swiftPM(packageRoot: URL)
    case xcworkspace(workspaceFile: URL, root: URL)
    case xcode(projectFile: URL, root: URL)
    case plain(root: URL)

    /// Detect the kind of project rooted at `root`.
    ///
    /// Order: `Package.swift` > `*.xcworkspace` > `*.xcodeproj` > plain.
    /// SwiftPM wins over everything (SourceKit-LSP convention). Workspace
    /// wins over project — if both exist, the workspace is the user's
    /// intended entry point.
    static func detect(at root: URL) -> ProjectKind {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            return .swiftPM(packageRoot: root)
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else {
            return .plain(root: root)
        }
        for entry in entries.sorted() where entry.hasSuffix(".xcworkspace") {
            return .xcworkspace(workspaceFile: root.appendingPathComponent(entry), root: root)
        }
        for entry in entries.sorted() where entry.hasSuffix(".xcodeproj") {
            return .xcode(projectFile: root.appendingPathComponent(entry), root: root)
        }
        return .plain(root: root)
    }

    /// The directory we walk for `.swift` files.
    var rootURL: URL {
        switch self {
        case .swiftPM(let r): return r
        case .xcworkspace(_, let r): return r
        case .xcode(_, let r): return r
        case .plain(let r): return r
        }
    }
}
