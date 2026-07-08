/// Maps a source file's imported modules to the accessibility ``Frontend``(s) that apply.
///
/// Pure and side-effect-free: it takes the set of imported module names (already
/// extracted from the source) and returns the frontends whose detectors should run.
/// A file importing both `SwiftUI` and `SwiftCLIKit` resolves to both `.swiftUI` and
/// `.cli` — both detectors run over it.
public enum FrontendResolver {

    /// Resolve the applicable frontends for a file, given its imported module names.
    ///
    /// - Parameter importedModules: Module names from the file's `import` statements
    ///   (e.g. `["SwiftUI", "Foundation"]`).
    /// - Returns: The set of frontends whose detectors apply. Empty when none match —
    ///   the file is then skipped, matching the auditor's existing "non-UI files are
    ///   ignored" behavior.
    public static func resolve(importedModules: Set<String>) -> Set<Frontend> {
        var frontends: Set<Frontend> = []
        if importedModules.contains("SwiftUI") {
            frontends.insert(.swiftUI)
        }
        if importedModules.contains("SwiftCLIKit") || importedModules.contains("ArgumentParser") {
            frontends.insert(.cli)
        }
        if importedModules.contains("JavaScriptKit") {
            frontends.insert(.web)
        }
        return frontends
    }
}
