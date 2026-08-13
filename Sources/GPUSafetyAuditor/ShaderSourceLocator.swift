import Foundation

/// Finds shader source in both forms it takes, and records which one it read.
///
/// ## Why both forms are mandatory
///
/// A codebase can exclude its `.metal` files from every target — to keep the Metal
/// toolchain out of a Playground build, say — and ship the shaders that actually run
/// as Swift string literals handed to `makeLibrary(source:)`. In the motivating
/// codebase that is exactly what happened: auditing `.metal` files alone reported
/// eight defects in code the compiler never sees, and missed the two kernels that
/// ship.
///
/// So a checker that reads only `.metal` files can be simultaneously loud and
/// useless. Worse, it looks thorough. This locator reads both and reports which,
/// because a finding in an excluded file is a statement about dead code and must not
/// be presented as a statement about the program.
public enum ShaderSourceLocator {

    /// A shader source found on disk, with its text.
    public struct Located: Sendable, Equatable {
        /// Where it came from.
        public let source: ShaderSource
        /// The Metal source text.
        public let text: String
    }

    /// Metal source embedded in a Swift string literal.
    ///
    /// Recognised by content rather than by tracing the value to
    /// `makeLibrary(source:)`: a multi-line string literal containing a `kernel void`
    /// declaration is Metal by any reasonable reading, and tracing the dataflow adds
    /// a great deal of machinery to reach the same set.
    ///
    /// - Parameters:
    ///   - swiftSource: The contents of a `.swift` file.
    ///   - path: That file's path, carried onto the finding.
    /// - Returns: One entry per literal that looks like Metal.
    public static func embeddedShaders(in swiftSource: String, path: String) -> [Located] {
        var results: [Located] = []
        var searchStart = swiftSource.startIndex

        while let open = swiftSource.range(of: "\"\"\"", range: searchStart..<swiftSource.endIndex) {
            guard let close = swiftSource.range(
                of: "\"\"\"", range: open.upperBound..<swiftSource.endIndex) else { break }
            let body = String(swiftSource[open.upperBound..<close.lowerBound])
            if looksLikeMetal(body) {
                let line = MetalKernelParser.lineNumber(of: open.lowerBound, in: swiftSource)
                results.append(Located(source: .embedded(path: path, line: line), text: body))
            }
            searchStart = close.upperBound
        }
        return results
    }

    /// Whether a string literal's contents are Metal Shading Language.
    ///
    /// Requires a `kernel` entry point. A literal merely mentioning `metal` — a
    /// diagnostic string, a file name — is not shader source, and treating it as
    /// such produces findings in text.
    static func looksLikeMetal(_ text: String) -> Bool {
        guard text.contains("kernel") else { return false }
        return !MetalKernelParser.kernels(
            in: text, source: .metalFile(path: "", excludedFromTarget: false)).isEmpty
    }

    /// Whether a `.metal` file is excluded from every target in the manifest.
    ///
    /// Read syntactically from `exclude:` lists. A file no target compiles is dead,
    /// and any kernel in it is dead with it.
    ///
    /// - Parameters:
    ///   - metalPath: Path of the `.metal` file, relative to the package root.
    ///   - manifest: Contents of `Package.swift`.
    /// - Returns: `true` when the manifest names the file, or a directory containing
    ///   it, in an `exclude:` list.
    public static func isExcluded(metalPath: String, manifest: String) -> Bool {
        let fileName = (metalPath as NSString).lastPathComponent
        var searchStart = manifest.startIndex
        while let exclude = manifest.range(
            of: "exclude:", range: searchStart..<manifest.endIndex) {
            guard let open = manifest[exclude.upperBound...].firstIndex(of: "["),
                  let close = manifest[open...].firstIndex(of: "]") else {
                searchStart = exclude.upperBound
                continue
            }
            let list = String(manifest[manifest.index(after: open)..<close])
            for entry in list.split(separator: ",") {
                let cleaned = entry.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\""))
                guard !cleaned.isEmpty else { continue }
                if cleaned == fileName || metalPath.hasSuffix(cleaned)
                    || metalPath.contains("/\(cleaned)/") || cleaned.hasSuffix(fileName) {
                    return true
                }
            }
            searchStart = close
        }
        return false
    }
}
