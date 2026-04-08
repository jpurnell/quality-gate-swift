import Foundation
import SwiftSyntax
import SwiftParser

/// Per-declaration syntactic facts collected from a single source file.
///
/// `IndexStorePass` consults this map after the index identifies a candidate
/// dead symbol, in order to apply the v2 allow-list (public API of library
/// targets, `@objc` and other dynamic-dispatch markers, `// LIVE:` exemptions,
/// `@main` entry points).
struct DeclFact: Sendable {
    var line: Int
    var name: String
    var isPublic: Bool        // public or open
    var isObjC: Bool          // @objc / @IBAction / @IBOutlet / @objcMembers on enclosing
    var isMainAttr: Bool      // declaration is `@main` or contained in a `@main` type
    var isExempted: Bool      // `// LIVE:` on declaration line or the line above
    var isInit: Bool
    var isEnumCase: Bool
    var isCodingKey: Bool
}

/// Lexical range of a declaration: line span of the whole decl plus the
/// line of its name token (the "decl name line" — the same coordinate
/// IndexStoreDB records for the symbol's definition occurrence).
struct DeclRange: Sendable {
    var startLine: Int
    var endLine: Int
    var nameLine: Int
}

/// Index of `DeclFact` keyed by `(absoluteFilePath, line)`.
///
/// IndexStoreDB gives us file+line for every definition occurrence; we use
/// that to look facts up cheaply. We also store decl ranges so the cross-
/// module pass can compute the enclosing-decl of a reference occurrence
/// purely lexically — IndexStoreDB's `.containedBy` / `.calledBy` relations
/// turn out to be unreliable for many Swift constructs.
struct LivenessIndex: Sendable {
    private var facts: [String: [Int: DeclFact]] = [:]
    private var ranges: [String: [DeclRange]] = [:]
    /// Set of file paths that contain `// LIVE:` on the *previous* line of
    /// a decl — we just store all `// LIVE:` line numbers per file and check
    /// `line` and `line - 1` at lookup time.
    private var liveLines: [String: Set<Int>] = [:]

    /// Resolves symlinks and `..` components so that FileManager paths
    /// (used during ingestion) and IndexStoreDB paths (used during
    /// lookup, which are typically already canonicalized to e.g.
    /// `/private/tmp/...`) end up with the same key.
    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    mutating func ingest(file: String, source: String) {
        let key = Self.normalize(file)
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: key, tree: tree)

        // Collect `// LIVE:` line numbers from raw source — comments aren't
        // attached to declarations in the syntax tree directly, but a line
        // sweep is fast and unambiguous.
        var liveSet: Set<Int> = []
        for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.contains("// LIVE:") || line.contains("//LIVE:") {
                liveSet.insert(idx + 1)
            }
        }
        liveLines[key] = liveSet

        let visitor = DeclFactVisitor(file: key, converter: converter, liveLines: liveSet)
        visitor.walk(tree)
        facts[key] = visitor.facts
        ranges[key] = visitor.ranges
    }

    func fact(file: String, line: Int) -> DeclFact? {
        facts[Self.normalize(file)]?[line]
    }

    /// Returns the *innermost* decl-name line whose range contains `line`,
    /// or `nil` if `line` is at top level (e.g. main.swift script body).
    func enclosingDeclNameLine(file: String, line: Int) -> Int? {
        guard let rs = ranges[Self.normalize(file)] else { return nil }
        var best: DeclRange?
        for r in rs where r.startLine <= line && r.endLine >= line {
            if best == nil
                || (r.endLine - r.startLine) < (best!.endLine - best!.startLine) {
                best = r
            }
        }
        return best?.nameLine
    }

    func hasLiveExemption(file: String, line: Int) -> Bool {
        guard let set = liveLines[Self.normalize(file)] else { return false }
        return set.contains(line) || set.contains(line - 1)
    }
}

// MARK: - Visitor

private final class DeclFactVisitor: SyntaxVisitor {
    let file: String
    let converter: SourceLocationConverter
    let liveLines: Set<Int>
    /// `@main`-annotated type names — methods inside them are entry points.
    private var mainTypeDepth = 0
    /// Members of a `public protocol` are implicitly public regardless of
    /// the func's own modifiers; track that context here.
    private var publicProtocolDepth = 0
    /// Inside a `enum X: CodingKey` declaration, every case is referenced
    /// only via the compiler-synthesized `Codable` machinery, which the
    /// index store doesn't see. Treat such cases as roots.
    private var codingKeyEnumDepth = 0
    var facts: [Int: DeclFact] = [:]
    var ranges: [DeclRange] = []

    private func recordRange(_ node: some SyntaxProtocol, nameLine: Int) {
        let start = node.startLocation(converter: converter).line
        let end = node.endLocation(converter: converter).line
        ranges.append(DeclRange(startLine: start, endLine: end, nameLine: nameLine))
    }

    init(file: String, converter: SourceLocationConverter, liveLines: Set<Int>) {
        self.file = file
        self.converter = converter
        self.liveLines = liveLines
        super.init(viewMode: .sourceAccurate)
    }

    // Detect `@main` on type decls and bump a depth counter so nested decls
    // know they live inside an entry-point type.
    private func enterTypeIfMain(_ attrs: AttributeListSyntax) {
        if hasAttribute(attrs, named: "main") { mainTypeDepth += 1 }
    }
    private func leaveTypeIfMain(_ attrs: AttributeListSyntax) {
        if hasAttribute(attrs, named: "main") { mainTypeDepth -= 1 }
    }

    private func hasAttribute(_ attrs: AttributeListSyntax, named target: String) -> Bool {
        for attr in attrs {
            if let a = attr.as(AttributeSyntax.self),
               let name = a.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
               name == target {
                return true
            }
        }
        return false
    }

    private func isPublicOrOpen(_ modifiers: DeclModifierListSyntax) -> Bool {
        for m in modifiers {
            let k = m.name.tokenKind
            if k == .keyword(.public) || k == .keyword(.open) { return true }
        }
        return false
    }

    private func isObjC(_ attrs: AttributeListSyntax) -> Bool {
        for attr in attrs {
            guard let a = attr.as(AttributeSyntax.self) else { continue }
            let name = a.attributeName.as(IdentifierTypeSyntax.self)?.name.text ?? ""
            if name == "objc" || name == "IBAction" || name == "IBOutlet" || name == "_cdecl" || name == "_silgen_name" {
                return true
            }
        }
        return false
    }

    private func record(line: Int, name: String, isPublic: Bool, isObjC: Bool, isInit: Bool = false, isEnumCase: Bool = false) {
        let exempted = liveLines.contains(line) || liveLines.contains(line - 1)
        facts[line] = DeclFact(
            line: line,
            name: name,
            isPublic: isPublic,
            isObjC: isObjC,
            isMainAttr: mainTypeDepth > 0,
            isExempted: exempted,
            isInit: isInit,
            isEnumCase: isEnumCase,
            isCodingKey: isEnumCase && codingKeyEnumDepth > 0
        )
    }

    // MARK: visits

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let line = node.name.startLocation(converter: converter).line
        let isPub = isPublicOrOpen(node.modifiers) || publicProtocolDepth > 0
        record(
            line: line,
            name: node.name.text,
            isPublic: isPub,
            isObjC: isObjC(node.attributes)
        )
        recordRange(node, nameLine: line)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let line = node.name.startLocation(converter: converter).line
        let isPub = isPublicOrOpen(node.modifiers)
        record(line: line, name: node.name.text, isPublic: isPub, isObjC: false)
        recordRange(node, nameLine: line)
        if isPub { publicProtocolDepth += 1 }
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) {
        if isPublicOrOpen(node.modifiers) { publicProtocolDepth -= 1 }
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let line = node.initKeyword.startLocation(converter: converter).line
        record(
            line: line,
            name: "init",
            isPublic: isPublicOrOpen(node.modifiers),
            isObjC: isObjC(node.attributes),
            isInit: true
        )
        recordRange(node, nameLine: line)
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let line = node.subscriptKeyword.startLocation(converter: converter).line
        record(
            line: line,
            name: "subscript",
            isPublic: isPublicOrOpen(node.modifiers) || publicProtocolDepth > 0,
            isObjC: isObjC(node.attributes)
        )
        recordRange(node, nameLine: line)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isPub = isPublicOrOpen(node.modifiers)
        let objc = isObjC(node.attributes)
        for binding in node.bindings {
            if let pat = binding.pattern.as(IdentifierPatternSyntax.self) {
                let line = pat.identifier.startLocation(converter: converter).line
                record(line: line, name: pat.identifier.text, isPublic: isPub, isObjC: objc)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for el in node.elements {
            let line = el.name.startLocation(converter: converter).line
            record(line: line, name: el.name.text, isPublic: false, isObjC: false, isEnumCase: true)
        }
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let line = node.name.startLocation(converter: converter).line
        record(line: line, name: node.name.text, isPublic: isPublicOrOpen(node.modifiers), isObjC: isObjC(node.attributes))
        recordRange(node, nameLine: line)
        enterTypeIfMain(node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { leaveTypeIfMain(node.attributes) }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let line = node.name.startLocation(converter: converter).line
        record(line: line, name: node.name.text, isPublic: isPublicOrOpen(node.modifiers), isObjC: isObjC(node.attributes))
        recordRange(node, nameLine: line)
        enterTypeIfMain(node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { leaveTypeIfMain(node.attributes) }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let line = node.name.startLocation(converter: converter).line
        record(line: line, name: node.name.text, isPublic: isPublicOrOpen(node.modifiers), isObjC: isObjC(node.attributes))
        recordRange(node, nameLine: line)
        enterTypeIfMain(node.attributes)
        if isCodingKeyEnum(node) { codingKeyEnumDepth += 1 }
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) {
        leaveTypeIfMain(node.attributes)
        if isCodingKeyEnum(node) { codingKeyEnumDepth -= 1 }
    }

    /// Recognises both `enum X: CodingKey` and the conventional name
    /// `enum CodingKeys` (which is what `Codable` synthesis looks for).
    private func isCodingKeyEnum(_ node: EnumDeclSyntax) -> Bool {
        if node.name.text == "CodingKeys" { return true }
        if let clause = node.inheritanceClause,
           clause.trimmedDescription.contains("CodingKey") {
            return true
        }
        return false
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // Extensions don't have a name token; use the start line as the
        // anchor so members inside the extension can find an enclosing
        // range when needed.
        let line = node.extensionKeyword.startLocation(converter: converter).line
        recordRange(node, nameLine: line)
        return .visitChildren
    }
}
