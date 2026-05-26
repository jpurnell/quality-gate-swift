# Checker Development Guide

How to build a new quality-gate checker from scratch. This guide covers the protocol, wiring, testing patterns, and common SwiftSyntax recipes so you don't reinvent the wheel.

---

## 1. Core Protocol: `QualityChecker`

Every checker implements this protocol from `QualityGateCore`:

```swift
public protocol QualityChecker: Sendable {
    var id: String { get }           // kebab-case CLI identifier: "hig-auditor", "safety"
    var name: String { get }         // human-readable: "HIG Auditor", "Safety Auditor"
    func check(configuration: Configuration) async throws -> CheckResult
}
```

- `id` is used in `--check <id>` on the CLI and in configuration YAML.
- `check()` must be `async` and `Sendable` (thread-safe).
- Return `CheckResult` with status, diagnostics, overrides, and duration.

### Optional: `FixableChecker`

If your checker can auto-fix issues, also conform to `FixableChecker`:

```swift
public protocol FixableChecker: QualityChecker {
    var fixDescription: String { get }
    func fix(diagnostics: [Diagnostic], configuration: Configuration) async throws -> FixResult
}
```

- `fix()` is only called when the user passes `--fix`.
- Create backups before modifying files.
- Return unfixed diagnostics in `FixResult.unfixed`.

---

## 2. Result Types

### `CheckResult`

```swift
public struct CheckResult: Sendable, Codable, Equatable {
    public let checkerId: String
    public let status: Status           // .passed, .failed, .warning, .skipped
    public let diagnostics: [Diagnostic]
    public let overrides: [DiagnosticOverride]
    public let duration: Duration
}
```

Rule of thumb: if `diagnostics` is empty, status is `.passed`. If any diagnostic has `.error` or `.warning` severity, status is `.failed`.

### `Diagnostic`

```swift
public struct Diagnostic: Sendable, Equatable {
    public let severity: Severity       // .error, .warning, .note
    public let message: String
    public let filePath: String?
    public let lineNumber: Int?         // 1-based
    public let columnNumber: Int?       // 1-based
    public let ruleId: String?          // "hig.settings-scene", "safety.force-unwrap"
    public let suggestedFix: String?
}
```

- Always include `filePath` and `lineNumber` when possible.
- `ruleId` should be `<checker-prefix>.<rule-name>` in kebab-case.
- `suggestedFix` is shown to the user as a hint.

### `DiagnosticOverride`

When a user suppresses a finding with an inline comment:

```swift
public struct DiagnosticOverride: Sendable, Codable, Equatable {
    public let ruleId: String
    public let justification: String
    public let filePath: String?
    public let lineNumber: Int?
}
```

---

## 3. Standard Checker Structure

```
Sources/MyChecker/
├── MyChecker.swift              # QualityChecker implementation
├── MyVisitor.swift              # SyntaxVisitor subclass (if AST-based)
└── MyRules.swift                # Rule ID constants and messages (optional)

Tests/MyCheckerTests/
└── MyCheckerTests.swift         # Swift Testing suite
```

### Skeleton Implementation

```swift
import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

public struct MyChecker: QualityChecker, Sendable {
    public let id = "my-checker"
    public let name = "My Checker"

    public init() {}

    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []

        if fileManager.fileExists(atPath: sourcesPath) {
            let result = try await auditDirectory(
                at: sourcesPath, configuration: configuration
            )
            allDiagnostics.append(contentsOf: result.diagnostics)
            allOverrides.append(contentsOf: result.overrides)
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            overrides: allOverrides,
            duration: duration
        )
    }

    // Exposed for unit testing without filesystem
    public func auditSource(
        _ source: String,
        fileName: String
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let sourceLines = source.components(separatedBy: "\n")

        let visitor = MyVisitor(
            fileName: fileName,
            converter: converter,
            sourceLines: sourceLines
        )
        visitor.walk(tree)

        return (visitor.diagnostics, visitor.overrides)
    }

    private func auditDirectory(
        at path: String,
        configuration: Configuration
    ) async throws -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return ([], [])
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            if shouldExclude(path: fullPath, patterns: configuration.excludePatterns) {
                continue
            }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSource(source, fileName: fullPath)
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                continue
            }
        }

        return (diagnostics, overrides)
    }

    private func shouldExclude(path: String, patterns: [String]) -> Bool {
        patterns.contains { path.contains($0) }
    }
}
```

### Skeleton Visitor

```swift
import SwiftSyntax
import QualityGateCore

final class MyVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let sourceLines: [String]

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    init(fileName: String,
         converter: SourceLocationConverter,
         sourceLines: [String]) {
        self.fileName = fileName
        self.converter = converter
        self.sourceLines = sourceLines
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Your detection logic here
        return .visitChildren
    }
}
```

---

## 4. Wiring Into the Project

Three places need changes:

### Package.swift

```swift
// 1. Add product
.library(name: "MyChecker", targets: ["MyChecker"]),

// 2. Add target
.target(
    name: "MyChecker",
    dependencies: [
        "QualityGateCore",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
    ]
),
.testTarget(
    name: "MyCheckerTests",
    dependencies: ["MyChecker"]
),

// 3. Add to QualityGateCLI dependencies
.executableTarget(
    name: "QualityGateCLI",
    dependencies: [
        // ... existing deps ...
        "MyChecker",
    ]
),
```

### QualityGateCLI.swift

```swift
// 1. Add import
import MyChecker

// 2. Add to allCheckers array
let allCheckers: [any QualityChecker] = [
    // ... existing checkers ...
    MyChecker(),
    // ...
]
```

### Configuration.swift (optional)

If your checker needs per-checker configuration:

```swift
// 1. Define config struct
public struct MyCheckerConfig: Sendable, Codable, Equatable {
    public let someOption: Bool
    public static let `default` = MyCheckerConfig(someOption: true)
}

// 2. Add to Configuration
public let myChecker: MyCheckerConfig

// 3. Add to init() with default
myChecker: MyCheckerConfig = .default,
```

---

## 5. Testing Pattern

Use Swift Testing with string literal source fixtures:

```swift
import Testing
@testable import MyChecker
import QualityGateCore

@Suite("My Checker Tests")
struct MyCheckerTests {
    let checker = MyChecker()

    @Test("Detects forbidden pattern")
    func detectsForbiddenPattern() {
        let source = """
        import Foundation
        let x = try! something()
        """
        let result = checker.auditSource(source, fileName: "Test.swift")
        #expect(!result.diagnostics.isEmpty)
        #expect(result.diagnostics.first?.ruleId == "my-checker.force-try")
    }

    @Test("Passes clean code")
    func passesCleanCode() {
        let source = """
        import Foundation
        let x = try? something()
        """
        let result = checker.auditSource(source, fileName: "Test.swift")
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Exemption suppresses diagnostic")
    func exemptionWorks() {
        let source = """
        // MY-EXEMPT: needed for bootstrap
        let x = try! something()
        """
        let result = checker.auditSource(source, fileName: "Test.swift")
        #expect(result.diagnostics.isEmpty)
        #expect(!result.overrides.isEmpty)
    }
}
```

No SwiftUI/AppKit/UIKit framework needed at test time — you're testing AST analysis, not runtime behavior.

---

## 6. SwiftSyntax Recipes

### Detecting Function Calls

```swift
override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    // Direct call: someFunction()
    if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
        let name = ref.baseName.text  // "someFunction"
    }

    // Member call: object.method()
    if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
        let methodName = member.declName.baseName.text  // "method"
    }

    return .visitChildren
}
```

### Detecting Type Conformances

```swift
override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    let name = node.name.text

    if let inheritance = node.inheritanceClause {
        for type in inheritance.inheritedTypes {
            let typeName = type.type.trimmedDescription
            if typeName == "View" {
                // This struct conforms to View
            }
        }
    }

    return .visitChildren
}
```

### Detecting Attributes

```swift
override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    let hasMain = node.attributes.contains { element in
        guard let attr = element.as(AttributeSyntax.self) else { return false }
        return attr.attributeName.trimmedDescription == "main"
    }
    return .visitChildren
}
```

### Detecting Member Access (static properties like `Color.blue`)

```swift
override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
    if let base = node.base?.as(DeclReferenceExprSyntax.self) {
        let typeName = base.baseName.text         // "Color"
        let memberName = node.declName.baseName.text  // "blue"
    }
    return .visitChildren
}
```

### Checking Function Call Arguments

```swift
override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    let hasPlacement = node.arguments.contains { arg in
        arg.label?.text == "placement"
    }

    for arg in node.arguments {
        let label = arg.label?.text       // "placement", "action", nil for positional
        let value = arg.expression.trimmedDescription  // ".primaryAction"
    }

    return .visitChildren
}
```

### Walking Modifier Chains

SwiftUI modifier chains are nested `FunctionCallExprSyntax`. To check if a view has a specific modifier, walk up the parent chain:

```swift
func hasModifier(named name: String, from node: some SyntaxProtocol) -> Bool {
    var current: Syntax? = Syntax(node)
    while let parent = current?.parent {
        if let call = parent.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == name {
            return true
        }
        current = parent
    }
    return false
}
```

### Getting Source Location

```swift
let location = node.startLocation(converter: converter)
// location.line: Int (1-based)
// location.column: Int (1-based)
```

### Tracking Nested Scope (push/pop stacks)

For rules that depend on context (e.g., "inside a ToolbarItem"):

```swift
private var contextStack: [String] = []

override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    if extractName(node) == "ToolbarItem" {
        contextStack.append("ToolbarItem")
    }
    return .visitChildren
}

override func visitPost(_ node: FunctionCallExprSyntax) {
    if extractName(node) == "ToolbarItem" {
        contextStack.removeLast()
    }
}

var isInsideToolbar: Bool {
    contextStack.contains("ToolbarItem")
}
```

### Checking Nearby Comments (for exemptions)

Standard pattern used by all auditors:

```swift
func checkExemption(near line: Int, prefix: String, ruleId: String) -> DiagnosticOverride? {
    let linesToCheck = [line - 1, line]
        .filter { $0 >= 1 && $0 <= sourceLines.count }

    for lineNum in linesToCheck {
        let content = sourceLines[lineNum - 1]
        if content.contains(prefix) {
            let justification = content
                .components(separatedBy: prefix)
                .last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return DiagnosticOverride(
                ruleId: ruleId,
                justification: justification,
                filePath: fileName,
                lineNumber: lineNum
            )
        }
    }
    return nil
}
```

---

## 7. Exemption Conventions

Each checker defines its own exemption comment prefix:

| Checker | Prefix | Example |
|---------|--------|---------|
| SafetyAuditor | `// SAFETY:` | `// SAFETY: bootstrap requires force unwrap` |
| ConcurrencyAuditor | `// Justification:` | `// Justification: immutable after init` |
| HIGAuditor | `// HIG-EXEMPT:` | `// HIG-EXEMPT: single-purpose utility` |
| FloatingPointSafety | `// FP-SAFE:` | `// FP-SAFE: denominator checked upstream` |

Choose a prefix that's:
- Short and distinctive
- Unlikely to appear in normal comments
- Descriptive of the domain

---

## 8. Checklist: New Checker

- [ ] Create `Sources/MyChecker/` directory
- [ ] Implement `QualityChecker` protocol (optionally `FixableChecker`)
- [ ] Create `SyntaxVisitor` subclass for AST-based checks
- [ ] Define rule IDs with `<checker-prefix>.<rule-name>` pattern
- [ ] Add exemption comment support
- [ ] Add to Package.swift: product, target, test target
- [ ] Add to QualityGateCLI: import, register in `allCheckers`
- [ ] Add to QualityGateCLI dependencies in Package.swift
- [ ] Write tests with string literal source fixtures
- [ ] Add per-checker config to `Configuration.swift` (if needed)
- [ ] Write design proposal (if non-trivial feature)
- [ ] Run `swift test --filter MyCheckerTests` to verify
- [ ] Run full quality gate to verify no regressions

---

## 9. Existing Checkers as Reference

| Checker | Good example of... |
|---------|-------------------|
| SafetyAuditor | Basic pattern detection, exemptions, `auditSource()` for testing |
| ConcurrencyAuditor | Context tracking with push/pop stacks, attribute detection |
| RecursionAuditor | Complex cross-function analysis, multiple visitor passes |
| HIGAuditor | Platform-aware rules, `FixableChecker`, tiered severity |
| ComplexityAnalyzer | Call-graph building, per-checker configuration |
| AccessibilityAuditor | SwiftUI-specific modifier checking |
