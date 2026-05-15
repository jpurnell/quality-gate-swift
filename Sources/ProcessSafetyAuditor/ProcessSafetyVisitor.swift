import Foundation
import QualityGateCore
import SwiftSyntax

/// Walks a Swift syntax tree looking for pipe-buffer deadlock patterns.
///
/// Detects cases where `process.waitUntilExit()` is called before
/// `pipe.fileHandleForReading.readDataToEndOfFile()` in the same scope.
final class ProcessSafetyVisitor: SyntaxVisitor {
    let filePath: String
    let converter: SourceLocationConverter
    let sourceLines: [String]

    private(set) var diagnostics: [Diagnostic] = []

    init(filePath: String, converter: SourceLocationConverter, sourceLines: [String]) {
        self.filePath = filePath
        self.converter = converter
        self.sourceLines = sourceLines
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Scope Analysis

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            analyzeScope(body.statements)
        }
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            analyzeScope(body.statements)
        }
        return .skipChildren
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            analyzeScope(body.statements)
        }
        return .skipChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        analyzeScope(node.statements)
        return .skipChildren
    }

    // MARK: - Core Analysis

    private func analyzeScope(_ statements: CodeBlockItemListSyntax) {
        var waitCalls: [(varName: String, node: SyntaxProtocol)] = []
        var readCalls: [(varName: String, node: SyntaxProtocol)] = []

        for statement in statements {
            collectCalls(from: Syntax(statement), waitCalls: &waitCalls, readCalls: &readCalls)
        }

        for wait in waitCalls {
            let waitLine = lineNumber(of: wait.node)

            let hasReadBefore = readCalls.contains { read in
                lineNumber(of: read.node) < waitLine
            }

            if !hasReadBefore {
                let hasReadAfter = readCalls.contains { read in
                    lineNumber(of: read.node) > waitLine
                }

                if hasReadAfter {
                    let line = waitLine
                    let lineIndex = line - 1
                    if lineIndex >= 0, lineIndex < sourceLines.count,
                       sourceLines[lineIndex].contains("// process-safety:disable") {
                        continue
                    }

                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "waitUntilExit() called before readDataToEndOfFile() — pipe buffer can deadlock if output exceeds ~64 KB",
                        filePath: filePath,
                        lineNumber: line,
                        ruleId: "process.wait-before-read",
                        suggestedFix: "Read pipe data before calling waitUntilExit(), or use ProcessRunner.run()"
                    ))
                }
            }
        }
    }

    private func collectCalls(
        from node: Syntax,
        waitCalls: inout [(varName: String, node: SyntaxProtocol)],
        readCalls: inout [(varName: String, node: SyntaxProtocol)]
    ) {
        var worklist: [Syntax] = [node]
        while let current = worklist.popLast() {
            for child in current.children(viewMode: .sourceAccurate) {
                if let funcCall = child.as(FunctionCallExprSyntax.self) {
                    if let memberAccess = funcCall.calledExpression.as(MemberAccessExprSyntax.self) {
                        let methodName = memberAccess.declName.baseName.text

                        if methodName == "waitUntilExit" {
                            let varName = extractBaseName(from: memberAccess.base)
                            waitCalls.append((varName: varName, node: funcCall))
                        } else if methodName == "readDataToEndOfFile" {
                            let varName = extractBaseName(from: memberAccess.base)
                            readCalls.append((varName: varName, node: funcCall))
                        }
                    }
                }

                worklist.append(child)
            }
        }
    }

    private func extractBaseName(from expr: ExprSyntax?) -> String {
        guard let expr else { return "" }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return extractBaseName(from: member.base)
        }
        return expr.trimmedDescription
    }

    private func lineNumber(of node: SyntaxProtocol) -> Int {
        let loc = node.startLocation(converter: converter)
        return loc.line
    }
}
