import Foundation
import os

/// What kind of Swift project lives at a given root directory.
///
/// Detection drives both source enumeration and index-store location:
///
/// - `.swiftPM` — auto-build with `swift build -Xswiftc -index-store-path …`,
///   walk `Sources/` (and any other top-level dirs containing `.swift`).
/// - `.xcode` — locate an existing index store under
///   `~/Library/Developer/Xcode/DerivedData/`. No auto-build.
/// - `.plain` — syntactic pass only; cross-module is skipped with a `.note`.
public enum ProjectKind: Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "ProjectKind")
    case swiftPM(packageRoot: URL)
    case xcworkspace(workspaceFile: URL, root: URL)
    case xcode(projectFile: URL, root: URL)
    case plain(root: URL)

    /// Detect the kind of project rooted at `root`.
    ///
    /// Order: `Package.swift` > `*.xcworkspace` > `*.xcodeproj` > plain.
    public static func detect(at root: URL) -> ProjectKind {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { // SAFETY: CLI tool detects local project type
            return .swiftPM(packageRoot: root)
        }
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: root.path) // SAFETY: CLI tool detects local project type
        } catch {
            logger.warning("Could not list directory \(root.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
    public var rootURL: URL {
        switch self {
        case .swiftPM(let r): return r
        case .xcworkspace(_, let r): return r
        case .xcode(_, let r): return r
        case .plain(let r): return r
        }
    }
}
