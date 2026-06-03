import Foundation
import QualityGateCore

/// Cross-file concurrency analysis backed by IndexStoreDB (Pass 2).
///
/// Implements three rules that require whole-project visibility:
/// - `concurrency.sendable-non-sendable-stored-property` — stored properties
///   added in extensions in other files that break Sendable guarantees.
/// - `concurrency.sendable-crosses-isolation` — `@unchecked Sendable` types
///   never actually sent across isolation boundaries.
/// - `concurrency.preconcurrency-import-unnecessary` — `@preconcurrency import`
///   where no imported symbol is used in a Sendable-requiring context.
///
/// The analysis logic is split into pure functions (``analyzeStoredProperties``,
/// ``analyzeIsolationCrossings``, ``analyzePreconcurrencyImport``) so that
/// unit tests can exercise them without a live IndexStoreDB session. The
/// ``run(configuration:)`` entry point orchestrates the full index-backed pass.
///
/// ## Graceful degradation
/// When the index store is unavailable, the pass emits a single `.note`
/// diagnostic and returns — it never fails the quality gate.
public enum ConcurrencyIndexPass: Sendable {

    // MARK: - Data types

    /// Describes a stored property discovered via the index.
    public struct StoredPropertyInfo: Sendable {
        /// Property name.
        public let name: String
        /// Type annotation text (e.g. "(Int) -> Void", "String").
        public let typeName: String
        /// Whether the property is declared with `var` (mutable).
        public let isMutable: Bool
        /// Whether the property type is known to conform to Sendable.
        public let isSendable: Bool
        /// File where this property is declared.
        public let file: String
        /// Line number of the declaration.
        public let line: Int

        /// Creates a stored property info record.
        public init(name: String, typeName: String, isMutable: Bool, isSendable: Bool, file: String, line: Int) {
            self.name = name
            self.typeName = typeName
            self.isMutable = isMutable
            self.isSendable = isSendable
            self.file = file
            self.line = line
        }
    }

    /// Describes a usage site of an `@unchecked Sendable` type.
    public struct UsageSite: Sendable {
        /// File where the type is used.
        public let file: String
        /// Line number of the usage.
        public let line: Int
        /// Whether this usage crosses an isolation boundary (actor hop, Task, etc.).
        public let crossesIsolation: Bool

        /// Creates a usage site record.
        public init(file: String, line: Int, crossesIsolation: Bool) {
            self.file = file
            self.line = line
            self.crossesIsolation = crossesIsolation
        }
    }

    // MARK: - Rule 1: sendable-non-sendable-stored-property

    /// Analyzes stored properties of a Sendable type for cross-file violations.
    ///
    /// Pass 1 only sees properties declared in the same file as the Sendable
    /// conformance. This function checks ALL stored properties (including those
    /// from extensions in other files) and flags any that are non-Sendable or
    /// mutable, skipping those in the same file as the type declaration
    /// (already handled by Pass 1).
    ///
    /// - Parameters:
    ///   - typeName: The name of the Sendable type being checked.
    ///   - declaredFile: The file where the type is declared with Sendable conformance.
    ///   - storedProperties: All stored properties found across all files.
    /// - Returns: Diagnostics for any cross-file violations found.
    public static func analyzeStoredProperties(
        typeName: String,
        declaredFile: String,
        storedProperties: [StoredPropertyInfo]
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        for property in storedProperties {
            // Skip same-file properties — Pass 1 already handles them.
            guard property.file != declaredFile else { continue }

            if property.isMutable {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Sendable type '\(typeName)' has mutable stored property '\(property.name)' declared in \(property.file); this breaks the Sendable contract",
                    filePath: property.file,
                    lineNumber: property.line,
                    columnNumber: 1,
                    ruleId: "concurrency.sendable-non-sendable-stored-property",
                    suggestedFix: "Make '\(property.name)' immutable, or move it to the type's primary declaration file."
                ))
            } else if !property.isSendable {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Sendable type '\(typeName)' has non-Sendable stored property '\(property.name)' (type: \(property.typeName)) declared in \(property.file)",
                    filePath: property.file,
                    lineNumber: property.line,
                    columnNumber: 1,
                    ruleId: "concurrency.sendable-non-sendable-stored-property",
                    suggestedFix: "Ensure '\(property.name)' conforms to Sendable, or use @unchecked Sendable with a justification."
                ))
            }
        }

        return diagnostics
    }

    // MARK: - Rule 2: sendable-crosses-isolation

    /// Analyzes whether an `@unchecked Sendable` type is actually sent across isolation boundaries.
    ///
    /// If no usage site crosses an isolation boundary, the `@unchecked Sendable`
    /// annotation may be unnecessary. Types with zero usage sites are not flagged
    /// (we cannot prove the annotation is unnecessary without evidence).
    ///
    /// - Parameters:
    ///   - typeName: The name of the `@unchecked Sendable` type.
    ///   - usageSites: All usage sites found across the project.
    /// - Returns: A diagnostic if the annotation appears unnecessary, or empty array.
    public static func analyzeIsolationCrossings(
        typeName: String,
        usageSites: [UsageSite]
    ) -> [Diagnostic] {
        // No usage sites — we cannot prove the annotation is unnecessary.
        guard !usageSites.isEmpty else { return [] }

        let crossesAny = usageSites.contains { $0.crossesIsolation }
        if crossesAny { return [] }

        return [
            Diagnostic(
                severity: .warning,
                message: "@unchecked Sendable on '\(typeName)' may be unnecessary — no usage site sends it across an isolation boundary",
                ruleId: "concurrency.sendable-crosses-isolation",
                suggestedFix: "Remove @unchecked Sendable if the type does not need to cross actor boundaries, or add a // Justification: comment."
            )
        ]
    }

    // MARK: - Rule 3: preconcurrency-import-unnecessary

    /// Analyzes whether a `@preconcurrency import` is actually needed.
    ///
    /// If none of the imported symbols are used in a Sendable-requiring context,
    /// the `@preconcurrency` attribute is unnecessary clutter.
    ///
    /// - Parameters:
    ///   - moduleName: The imported module name.
    ///   - file: The file containing the import.
    ///   - line: The line number of the import.
    ///   - importedSymbolsUsedInSendableContext: Whether any imported symbol is used
    ///     in a context that requires Sendable conformance.
    /// - Returns: A diagnostic if the import is unnecessary, or empty array.
    public static func analyzePreconcurrencyImport(
        moduleName: String,
        file: String,
        line: Int,
        importedSymbolsUsedInSendableContext: Bool
    ) -> [Diagnostic] {
        if importedSymbolsUsedInSendableContext { return [] }

        return [
            Diagnostic(
                severity: .note,
                message: "@preconcurrency import of '\(moduleName)' may be unnecessary — no imported symbol is used in a Sendable-requiring context",
                filePath: file,
                lineNumber: line,
                columnNumber: 1,
                ruleId: "concurrency.preconcurrency-import-unnecessary",
                suggestedFix: "Remove the @preconcurrency attribute from 'import \(moduleName)' if concurrency warnings have been resolved."
            )
        ]
    }

    // MARK: - Graceful degradation

    /// Returns a note diagnostic indicating that the index-backed pass was skipped.
    ///
    /// Used when the index store is unavailable, misconfigured, or the
    /// `useIndexStore` configuration option is disabled. This ensures the quality
    /// gate never fails solely because of a missing index.
    ///
    /// - Returns: A `.note` severity diagnostic.
    public static func unavailableNote() -> Diagnostic {
        Diagnostic(
            severity: .note,
            message: "Concurrency Pass 2 skipped: index store unavailable. Build the project to enable cross-file Sendable validation.",
            ruleId: "concurrency.index-pass.skipped"
        )
    }
}
