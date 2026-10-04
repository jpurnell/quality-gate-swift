import Foundation
import QualityGateCore

/// Decodes the serialized-diagnostics (`.dia`) file a compile job leaves behind.
///
/// The Swift driver gives every compile job an output file map, and the map names a `.dia` file
/// for it. The compiler rewrites that file whenever the job runs and leaves it alone when the
/// job is up to date — so it still holds a file's warnings after an incremental build that had
/// no reason to recompile the file, and therefore printed nothing about it.
///
/// The decoding itself is `TSCUtility.SerializedDiagnostics` from swift-tools-support-core,
/// vendored under `SerializedDiagnostics/` with its provenance in each file's header. This type
/// is the one seam between that code and the checker: it turns bytes into the gate's own
/// `Diagnostic`, in the form ``BuildChecker/parseBuildOutput(_:)`` produces for the same
/// diagnostic read from the build's printed output.
///
/// ## Usage
///
/// ```swift
/// import BuildChecker
///
/// do {
///     let diagnostics = try SerializedDiagnosticsReader.diagnostics(atPath: "/path/to/File.dia")
///     for diagnostic in diagnostics {
///         print(diagnostic.message)
///     }
/// } catch {
///     print("unreadable: \(error)")
/// }
/// ```
public enum SerializedDiagnosticsReader {
    /// The rule identifier carried by every compiler diagnostic, printed or recorded.
    public static let ruleId = "swift-compiler"

    /// Decodes the contents of a `.dia` file.
    ///
    /// Levels map onto the gate's three severities: `error` and `fatal` to `.error`, `warning`
    /// to `.warning`, `note` and `remark` to `.note`. A diagnostic recorded as `ignored` is
    /// dropped — the compiler did not report it either.
    ///
    /// - Parameter bytes: The file's contents.
    /// - Returns: The diagnostics the file records, in file order.
    /// - Throws: When `bytes` is not a well-formed serialized-diagnostics file — truncated,
    ///   overwritten, or not a `.dia` at all. Nothing traps.
    public static func diagnostics(fromBytes bytes: [UInt8]) throws -> [Diagnostic] {
        let serialized = try SerializedDiagnostics(bytes: bytes)
        return serialized.diagnostics.compactMap { recorded in
            guard let severity = severity(of: recorded.level) else { return nil }
            return Diagnostic(
                severity: severity,
                message: message(text: recorded.text, category: recorded.category),
                filePath: recorded.location?.filename,
                lineNumber: recorded.location.flatMap { Int(exactly: $0.line) },
                columnNumber: recorded.location.flatMap { Int(exactly: $0.column) },
                ruleId: ruleId
            )
        }
    }

    /// Reads and decodes the `.dia` file at `path`.
    ///
    /// - Parameter path: Path to a serialized-diagnostics file.
    /// - Returns: The diagnostics the file records, in file order.
    /// - Throws: When the file cannot be read or is not a well-formed `.dia`.
    public static func diagnostics(atPath path: String) throws -> [Diagnostic] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try diagnostics(fromBytes: [UInt8](data))
    }

    /// Renders a diagnostic's text as the compiler prints it: `text [#Group]` when the
    /// diagnostic belongs to a group, the bare text otherwise.
    ///
    /// The printed form is what ``BuildChecker/parseBuildOutput(_:)`` yields once hyperlink
    /// escapes are stripped, and the two must be identical for a diagnostic that is both
    /// printed and recorded to be reported once.
    ///
    /// - Parameters:
    ///   - text: The diagnostic message.
    ///   - category: The diagnostic group, if any.
    /// - Returns: The message as it appears in build output.
    static func message(text: String, category: String?) -> String {
        guard let category, !category.isEmpty else { return text }
        return "\(text) [#\(category)]"
    }

    private static func severity(of level: SerializedDiagnostics.Diagnostic.Level) -> Diagnostic.Severity? {
        switch level {
        case .ignored: return nil
        case .note, .remark: return .note
        case .warning: return .warning
        case .error, .fatal: return .error
        }
    }
}
