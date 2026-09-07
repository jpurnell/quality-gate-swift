import Foundation
import QualityGateCore

/// The macro plugins a package builds for itself.
///
/// ## Why the toolchain's plugin path is not enough
///
/// `Toolchain` already passes `-plugin-path` for swift-testing's macros, because they live
/// beside the compiler and every `@Test` block would otherwise fail on a missing implementation
/// rather than on anything the author wrote. A package's *own* macros are a different problem
/// with the same shape: `.macro(name: "MyMacrosImpl")` builds an executable into the package's
/// build directory, and a doc comment on a macro-annotated declaration cannot compile without
/// it.
///
/// Measured on a 100k-line package: 25 errors from one root cause, spread across the fences that
/// happened to use the package's own macros. Every one of them looked like a documentation
/// defect and none of them was — the same failure mode that made `PackageDescription` snippets
/// unreachable until `ManifestAPI` was added to the include path, and with the same consequence
/// if left alone: the natural response is to mark those fences illustrative, which manufactures
/// an exemption for a block the gate simply could not reach.
enum MacroPlugins {

    /// `-load-plugin-executable` flags for every macro target this package builds.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - buildDirectory: Where built products live, normally `.build/debug`.
    /// - Returns: Compiler flags, or empty when the package declares no macros or has not built
    ///   them. An unbuilt plugin yields nothing rather than a broken flag: the fence then fails
    ///   with the compiler's own "external macro implementation not found", which is a true
    ///   statement about the tree and points somewhere useful.
    static func flags(projectRoot: URL, buildDirectory: String) -> [String] {
        let manifest = projectRoot.appendingPathComponent("Package.swift")
        guard let source = SourceFileReader.read(manifest, checker: "doc-code") else { return [] }

        var flags: [String] = []
        for name in macroTargets(in: source) {
            let executable = (buildDirectory as NSString).appendingPathComponent(name)
            // SAFETY: CLI tool checks the package's own build directory for its macro plugin
            guard FileManager.default.fileExists(atPath: executable) else { continue }
            flags += ["-load-plugin-executable", "\(executable)#\(name)"]
        }
        return flags
    }

    /// The names of `.macro(name:)` targets the manifest declares.
    ///
    /// A deliberately narrow read of the manifest text. Parsing it properly means descending
    /// from the `Package(…)` call to its `targets:` argument — which this package does elsewhere
    /// for exactly this reason, because `.target(name:)` inside a `dependencies:` array is a
    /// reference rather than a declaration. `.macro(…)` does not appear in dependency lists, so
    /// the narrower read is sound here and stays in this module rather than reaching across one.
    static func macroTargets(in manifest: String) -> [String] {
        var names: [String] = []
        var searchRange = manifest.startIndex..<manifest.endIndex

        while let macro = manifest.range(of: #"\.macro\s*\(\s*name:\s*""#,
                                         options: .regularExpression, range: searchRange) {
            guard let close = manifest[macro.upperBound...].firstIndex(of: "\"") else { break }
            let name = String(manifest[macro.upperBound..<close])
            if !name.isEmpty { names.append(name) }
            searchRange = close..<manifest.endIndex
        }
        return names
    }
}
