import Foundation
import QualityGateCore
import SwiftSyntax

/// SwiftSyntax visitor that detects memory lifecycle issues in Swift classes.
///
/// Scans class declarations for:
/// - Stored `Task` properties without a `deinit` (`lifecycle-task-no-deinit`)
/// - Stored `Task` properties with a `deinit` that omits `.cancel()` (`lifecycle-task-no-cancel`)
/// - Strong stored delegate/parent/owner properties (`lifecycle-strong-delegate`)
///
/// Actor declarations are exempt from all rules since actors manage
/// their own isolation and lifecycle.
final class LifecycleVisitor: SyntaxVisitor {
    /// File path used in emitted diagnostics.
    let filePath: String
    /// Original source text, split into lines for comment scanning.
    let sourceLines: [String]
    /// Source location converter for accurate line numbers.
    let converter: SourceLocationConverter
    /// Configuration controlling delegate patterns and exemptions.
    let config: MemoryLifecycleConfig

    /// Collected diagnostics from the walk.
    private(set) var diagnostics: [Diagnostic] = []

    /// Creates a new lifecycle visitor.
    ///
    /// - Parameters:
    ///   - filePath: The file path for diagnostic messages.
    ///   - source: The full source text of the file.
    ///   - config: The memory lifecycle configuration.
    ///   - tree: The parsed syntax tree (used for SourceLocationConverter).
    init(filePath: String, source: String, config: MemoryLifecycleConfig, tree: SourceFileSyntax) {
        self.filePath = filePath
        self.sourceLines = source.components(separatedBy: "\n")
        self.converter = SourceLocationConverter(fileName: filePath, tree: tree)
        self.config = config
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Class Declarations

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let members = node.memberBlock.members

        // Collect stored Task properties (not exempt)
        var taskProperties: [(name: String, line: Int)] = []
        // Track deinit presence and body text
        var hasDeinit = false
        var deinitBodyText: String?

        for member in members {
            // Check for deinit
            if let deinitDecl = member.decl.as(DeinitializerDeclSyntax.self) {
                hasDeinit = true
                deinitBodyText = deinitDecl.body?.description
            }

            // Check for variable declarations
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            // Skip static properties
            let isStatic = varDecl.modifiers.contains { $0.name.text == "static" }
            guard !isStatic else { continue }

            let hasWeak = varDecl.modifiers.contains { $0.name.text == "weak" }
            let hasUnowned = varDecl.modifiers.contains { $0.name.text == "unowned" }

            for binding in varDecl.bindings {
                // Only stored properties (no accessor block)
                guard binding.accessorBlock == nil else { continue }

                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    continue
                }
                let propertyName = pattern.identifier.text
                let line = startLine(of: Syntax(varDecl))

                // Check for lifecycle:exempt comment
                guard !isLifecycleExempt(varDecl) else { continue }

                // Check for Task type
                if let typeAnnotation = binding.typeAnnotation {
                    let typeText = typeAnnotation.type.trimmedDescription
                    if isTaskType(typeText) {
                        taskProperties.append((name: propertyName, line: line))
                    }
                }

                // Check for strong delegate pattern
                let loweredName = propertyName.lowercased()
                let matchesPattern = config.delegatePatterns.contains { pattern in
                    loweredName.contains(pattern.lowercased())
                }
                if matchesPattern && !hasWeak && !hasUnowned {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "Stored property '\(propertyName)' matches delegate pattern and is not weak or unowned; this may cause a retain cycle",
                        filePath: filePath,
                        lineNumber: line,
                        columnNumber: 1,
                        ruleId: "lifecycle-strong-delegate",
                        suggestedFix: "Add 'weak' or 'unowned' modifier to '\(propertyName)'."
                    ))
                }
            }
        }

        // Emit Task lifecycle diagnostics
        if !taskProperties.isEmpty {
            if !hasDeinit {
                // lifecycle-task-no-deinit
                for prop in taskProperties {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "Class has stored Task property '\(prop.name)' but no deinit to cancel it; this may leak the task",
                        filePath: filePath,
                        lineNumber: prop.line,
                        columnNumber: 1,
                        ruleId: "lifecycle-task-no-deinit",
                        suggestedFix: "Add a deinit that calls \(prop.name).cancel()."
                    ))
                }
            } else if let bodyText = deinitBodyText {
                // lifecycle-task-no-cancel: deinit exists but doesn't call cancel()
                let containsCancel = bodyText.contains("cancel()")
                if !containsCancel {
                    for prop in taskProperties {
                        diagnostics.append(Diagnostic(
                            severity: .warning,
                            message: "Class has stored Task property '\(prop.name)' but deinit does not call cancel(); the task may outlive the object",
                            filePath: filePath,
                            lineNumber: prop.line,
                            columnNumber: 1,
                            ruleId: "lifecycle-task-no-cancel",
                            suggestedFix: "Add \(prop.name)?.cancel() or \(prop.name).cancel() to deinit."
                        ))
                    }
                }
            }
        }

        return .visitChildren
    }

    // MARK: - Actor Declarations (exempt)

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        // Actors manage their own isolation; skip all lifecycle checks.
        return .skipChildren
    }

    // MARK: - Helpers

    /// Returns whether a type annotation string represents a Task type.
    ///
    /// Matches: `Task<...>`, `Task<...>?`, `Task<...>!`, `Task`,
    /// `Optional<Task<...>>`.
    private func isTaskType(_ typeText: String) -> Bool {
        let trimmed = typeText.trimmingCharacters(in: .whitespaces)
        // Exact match "Task"
        if trimmed == "Task" { return true }
        // Starts with "Task<"
        if trimmed.hasPrefix("Task<") { return true }
        // Optional/IUO: ends with ? or ! after Task<...>
        let stripped = trimmed.replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .trimmingCharacters(in: .whitespaces)
        if stripped == "Task" || stripped.hasPrefix("Task<") { return true }
        // Optional<Task<...>>
        if trimmed.hasPrefix("Optional<Task") { return true }
        return false
    }

    /// Checks if a variable declaration has a trailing `// lifecycle:exempt` comment.
    ///
    /// Scans the source line containing the declaration for the marker text.
    private func isLifecycleExempt(_ varDecl: VariableDeclSyntax) -> Bool {
        // Check the full text of the declaration including trivia for the exempt marker
        let fullText = varDecl.description
        if fullText.contains("lifecycle:exempt") { return true }

        // Also check the source line
        let line = startLine(of: Syntax(varDecl))
        let zeroIndexed = line - 1
        guard zeroIndexed >= 0, zeroIndexed < sourceLines.count else { return false }
        return sourceLines[zeroIndexed].contains("lifecycle:exempt")
    }

    /// Returns the 1-based line number for a syntax node using the source location converter.
    private func startLine(of node: Syntax) -> Int {
        node.startLocation(converter: converter).line
    }
}
