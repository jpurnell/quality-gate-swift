import SwiftSyntax

/// `file: StaticString = #filePath, line: UInt = #line` → `sourceLocation: SourceLocation = #_sourceLocation`.
///
/// XCTest helpers forward the caller's position so a failure is reported where the helper
/// was called, not inside it. Swift Testing does the same with one value. A helper left with
/// the two XCTest parameters still compiles, but its `#expect`s no longer accept them, and
/// every failure lands on the helper's own line.
enum SourceLocationParameters {

    /// The rewritten list, or `nil` when it has no position parameters.
    static func replacement(
        for list: FunctionParameterListSyntax, render: (FunctionParameterSyntax) -> String
    ) -> String? {
        let parameters = Array(list)
        let positional = parameters.filter(isPositionParameter)
        guard !positional.isEmpty else { return nil }

        var rendered: [String] = []
        var placed = false
        for parameter in parameters {
            if isPositionParameter(parameter) {
                guard !placed else { continue }
                rendered.append("sourceLocation: SourceLocation = #_sourceLocation")
                placed = true
            } else {
                rendered.append(render(parameter.with(\.trailingComma, nil)))
            }
        }
        return rendered.joined(separator: ", ")
    }

    /// Whether `parameter` is `file: StaticString = #file[Path]` or `line: UInt = #line`.
    static func isPositionParameter(_ parameter: FunctionParameterSyntax) -> Bool {
        guard let macro = parameter.defaultValue?.value.as(MacroExpansionExprSyntax.self) else {
            return false
        }
        let type = parameter.type.trimmedDescription
        switch parameter.firstName.text {
        case "file": return type == "StaticString" && ["file", "filePath", "fileID"].contains(macro.macroName.text)
        case "line": return type == "UInt" && macro.macroName.text == "line"
        default: return false
        }
    }
}
