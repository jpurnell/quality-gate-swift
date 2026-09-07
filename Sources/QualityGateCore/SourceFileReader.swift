import Foundation
#if canImport(os)
import os
#endif

/// Reads a source file a checker was asked to examine, reporting files it could not read.
///
/// ## Why this exists
///
/// Every scanning checker walks a file list and reads each entry. The idiom that grew up
/// around that walk was:
///
/// ```swift
/// guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
/// ```
///
/// which silently drops any file that will not open — a permissions problem, a broken
/// symlink, a file deleted between the walk and the read, or text that is not valid UTF-8.
/// The checker then finishes and reports **passed**.
///
/// That verdict is a claim the run did not verify. The gate already refuses to make this
/// mistake at checker granularity — a run that stops early prints `NOT REACHED — 0 findings
/// from them means nothing` rather than implying the unreached checkers were clean. The same
/// reasoning applies one level down: zero findings in a file that was never read means
/// nothing either, and until now nothing said so.
///
/// ## What it does not change
///
/// Skipping remains the behaviour. A single unreadable file must not fail a whole checker,
/// and callers keep their `continue`. The difference is that the skip is now recorded, so a
/// clean report and a report full of holes stop looking identical.
public enum SourceFileReader {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "SourceFileReader")

    /// Reads a file for scanning, or returns `nil` and records why it was skipped.
    ///
    /// - Parameters:
    ///   - path: Filesystem path of the file to read.
    ///   - checker: The checker id doing the reading, so the log names who lost coverage.
    /// - Returns: The file's contents, or `nil` when it could not be read.
    public static func read(_ path: String, checker: String) -> String? {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            logger.warning(
                "\(checker, privacy: .public) skipped \(path, privacy: .public) — it could not be read, so its findings are unknown, not absent: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Reads a file for scanning, or returns `nil` and records why it was skipped.
    ///
    /// - Parameters:
    ///   - url: Location of the file to read.
    ///   - checker: The checker id doing the reading, so the log names who lost coverage.
    /// - Returns: The file's contents, or `nil` when it could not be read.
    public static func read(_ url: URL, checker: String) -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.warning(
                "\(checker, privacy: .public) skipped \(url.path, privacy: .public) — it could not be read, so its findings are unknown, not absent: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
