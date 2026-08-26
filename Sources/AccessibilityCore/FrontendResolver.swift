/// Maps a source file's imported modules to the accessibility ``Frontend``(s) that apply.
///
/// Pure and side-effect-free: it takes the set of imported module names (already
/// extracted from the source) and returns the frontends whose detectors should run.
/// A file importing both `SwiftUI` and `SwiftCLIKit` resolves to both `.swiftUI` and
/// `.cli` — both detectors run over it.
public enum FrontendResolver {

    /// Modules that mean a file speaks to a terminal — whether it imports one or is one.
    static let cliModules: Set<String> = ["SwiftCLIKit", "ArgumentParser"]

    /// Resolve the applicable frontends for a file, given its imported modules and the
    /// module that declares it.
    ///
    /// Imports alone are not enough for the CLI frontend. A terminal toolkit never imports
    /// itself — its own sources *are* the module — so resolving on imports selected every
    /// consumer of the toolkit, including its test target, and never the toolkit that
    /// actually writes escape sequences to a file descriptor. `declaringModule` closes that
    /// gap: it is checked against the same module list as the imports.
    ///
    /// - Parameters:
    ///   - importedModules: Module names from the file's `import` statements
    ///     (e.g. `["SwiftUI", "Foundation"]`).
    ///   - declaringModule: The name of the module the file belongs to, when known.
    ///     `nil` — the default — resolves on imports alone, as before.
    /// - Returns: The set of frontends whose detectors apply. Empty when none match —
    ///   the file is then skipped, matching the auditor's existing "non-UI files are
    ///   ignored" behavior.
    public static func resolve(
        importedModules: Set<String>,
        declaringModule: String? = nil
    ) -> Set<Frontend> {
        var frontends: Set<Frontend> = []
        if importedModules.contains("SwiftUI") {
            frontends.insert(.swiftUI)
        }
        let declaresCLI = declaringModule.map(cliModules.contains) ?? false
        if !importedModules.isDisjoint(with: cliModules) || declaresCLI {
            frontends.insert(.cli)
        }
        if importedModules.contains("JavaScriptKit") {
            frontends.insert(.web)
        }
        return frontends
    }
}
