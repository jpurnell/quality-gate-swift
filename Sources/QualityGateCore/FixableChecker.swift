import Foundation

/// A quality checker that can also apply fixes for the issues it detects.
///
/// Checkers that implement this protocol provide a `fix()` method
/// that programmatically applies the `suggestedFix` from their diagnostics.
/// The CLI invokes this only when `--fix` is explicitly passed.
///
/// ## Implementing a Fixable Checker
///
/// ```swift
/// struct MyChecker: FixableChecker {
///     let id = "my-checker"
///     let name = "My Checker"
///     let fixDescription = "Corrects formatting issues in source files."
///
///     func check(configuration: Configuration) async throws -> CheckResult {
///         // Detect issues...
///     }
///
///     func fix(
///         diagnostics: [Diagnostic],
///         configuration: Configuration
///     ) async throws -> FixResult {
///         // Apply fixes...
///     }
/// }
/// ```
///
/// ## Safety Contract
///
/// - `fix()` must never be called without `--fix` explicit opt-in from the user.
/// - `fix()` should create timestamped backups before modifying any file.
/// - `fix()` must only modify content that is provably wrong (surgical patches).
/// - `fix()` must preserve human-authored prose and project-specific context.
/// - Diagnostics that cannot be auto-fixed must be returned in `FixResult.unfixed`.
public protocol FixableChecker: QualityChecker {

    /// Human-readable description of what this checker's fix mode does.
    ///
    /// Shown to the user before applying fixes so they understand the impact.
    var fixDescription: String { get }

    /// Apply fixes for the given diagnostics.
    ///
    /// Only called when the user explicitly passes `--fix`. The diagnostics
    /// provided are from a prior `check()` call on the same project state.
    ///
    /// - Parameters:
    ///   - diagnostics: The diagnostics to fix (from a prior `check()` call).
    ///   - configuration: Project-specific configuration.
    /// - Returns: A fix result describing what was changed.
    /// - Throws: `QualityGateError` if fixes cannot be applied.
    func fix(
        diagnostics: [Diagnostic],
        configuration: Configuration
    ) async throws -> FixResult
}

/// The result of applying auto-fixes.
///
/// Contains both the list of files that were modified and any diagnostics
/// that could not be auto-fixed (requiring manual intervention).
///
/// ## MCP Schema
/// ```json
/// {
///   "modifications": [
///     {
///       "filePath": "development-guidelines/00_CORE_RULES/00_MASTER_PLAN.md",
///       "description": "Updated 6 module checkboxes and test counts",
///       "linesChanged": 12
///     }
///   ],
///   "unfixed": [...]
/// }
/// ```
public struct FixResult: Sendable, Codable, Equatable {
    /// Files that were modified by the fix operation.
    public let modifications: [FileModification]

    /// Diagnostics that could not be auto-fixed and require manual intervention.
    public let unfixed: [Diagnostic]

    /// Whether any files were actually changed.
    public var hasChanges: Bool { !modifications.isEmpty }

    /// Total number of lines changed across all modifications.
    public var totalLinesChanged: Int {
        modifications.reduce(0) { $0 + $1.linesChanged }
    }

    /// Creates a new fix result.
    ///
    /// - Parameters:
    ///   - modifications: Files that were modified.
    ///   - unfixed: Diagnostics that could not be auto-fixed.
    public init(modifications: [FileModification], unfixed: [Diagnostic]) {
        self.modifications = modifications
        self.unfixed = unfixed
    }

    /// A fix result indicating no changes were needed.
    public static let noChanges = FixResult(modifications: [], unfixed: [])
}

/// A single file modification made by a fixer.
///
/// Records what file was changed and a human-readable summary of the changes,
/// used for reporting to the user after a fix operation.
public struct FileModification: Sendable, Codable, Equatable {
    /// Absolute or relative path to the modified file.
    public let filePath: String

    /// Human-readable description of what changed in this file.
    public let description: String

    /// Number of lines that were changed (added + removed + modified).
    public let linesChanged: Int

    /// Path to the backup file created before modification.
    public let backupPath: String?

    /// Creates a new file modification record.
    ///
    /// - Parameters:
    ///   - filePath: Path to the modified file.
    ///   - description: What changed.
    ///   - linesChanged: Number of lines changed.
    ///   - backupPath: Path to the pre-modification backup, if created.
    public init(
        filePath: String,
        description: String,
        linesChanged: Int,
        backupPath: String? = nil
    ) {
        self.filePath = filePath
        self.description = description
        self.linesChanged = linesChanged
        self.backupPath = backupPath
    }
}
