import Foundation

/// Tells a dependency's build-graph chatter apart from a documentation finding.
///
/// ## Why this exists in the DocC parser at all
///
/// `doc-lint` runs `swift package generate-documentation`, a single command that builds the
/// package *and* runs DocC, so build-engine output and documentation diagnostics arrive
/// interleaved in one stream with no structural boundary between them. Splitting the phases is
/// the honest fix and is recorded as the preferred one; it is not available while the two share
/// a process and the late tasks — codesigning among them — emit after any plausible marker.
///
/// The location-less fallback pattern the parser uses cannot simply be dropped either: DocC
/// really does emit `warning: 'MyType' doesn't exist at '/MyModule/MyType'` with no file, and
/// deleting the pattern would lose real findings. The pattern is not too loose; it is applied to
/// build output that is not documentation at all.
///
/// ## The observed case, and the bound on the heuristic
///
/// `mlx-swift` ships a compiled metallib as a resource on a C++ target. SwiftPM synthesizes a
/// resource-only bundle for it, and the codesign task declares it mutates `Contents/MacOS` —
/// which a bundle with no executable never has. The project under test contributes nothing:
/// not its manifest, not its sources, not its config, and the dependency arrives transitively.
///
/// So the test is narrow on purpose: **every** absolute path in the message must lie under
/// `.build/`. A message naming real source is the project's business however it is shaped, and
/// one naming both is treated as the project's, because a conflict between a built artifact and
/// a source file is exactly the kind of thing a maintainer should see.
///
/// ## What this does not do
///
/// It does not silence the finding. The information stays visible as a note — the noise is real
/// and a maintainer may want to know their dependency graph produces it. Only the accounting
/// changes, so a gate can reach zero warnings for a project whose remaining finding belongs to
/// someone else's package. A warning nobody can act on, sitting permanently in a gate, teaches
/// a team that a non-zero count is normal, which is how a checker stops being trusted.
enum DependencyBuildNoise {

    /// Whether a location-less diagnostic message is a dependency's build-graph noise.
    ///
    /// - Parameter message: The diagnostic text, without its `warning:` prefix.
    /// - Returns: `true` when the message names at least one absolute path and every one of
    ///   them is inside a `.build/` directory.
    static func isNoise(_ message: String) -> Bool {
        let paths = absolutePaths(in: message)
        guard !paths.isEmpty else { return false }
        return paths.allSatisfy { $0.contains("/.build/") }
    }

    /// Every absolute path the message mentions.
    ///
    /// Paths arrive wrapped in quotes, parentheses, or nothing at all, so the scan takes runs
    /// beginning at `/` and stops at the delimiters that cannot appear inside one here.
    static func absolutePaths(in message: String) -> [String] {
        var paths: [String] = []
        var current: String?

        for character in message {
            if character == "/" , current == nil {
                current = "/"
                continue
            }
            guard var path = current else { continue }
            if character.isWhitespace || character == "'" || character == "\"" || character == ")" {
                paths.append(path)
                current = nil
            } else {
                path.append(character)
                current = path
            }
        }
        if let path = current { paths.append(path) }
        return paths.filter { $0.count > 1 }
    }
}
