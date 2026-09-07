import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Finds types this package declares whose names collide with the standard library.
///
/// Only the colliding names are collected. The question this answers is narrow — *does
/// a bare link to `Result` in this package have two possible meanings?* — and a full
/// symbol table would be a much larger thing built to answer it.
///
/// Declarations are read from the syntax tree rather than matched by line, because
/// the shapes that break a line scan are ordinary: a `struct Result` inside a string
/// literal, inside a comment, or mentioned in a doc comment that documents it. This
/// package's own fence extractor records what a naive scan costs — it counted 21
/// Swift doc fences where the tree finds 20, the difference being an inline code span
/// in prose.
public enum DeclaredTypes {

    /// Nesting-aware names of declarations whose name collides with the standard library.
    ///
    /// - Parameters:
    ///   - source: Swift source text.
    ///   - moduleName: The module the file belongs to, used to qualify a top-level type.
    ///   - names: Names worth looking for.
    /// - Returns: Bare name mapped to the path a reader should write instead —
    ///   `Result` to `GitProvenance/Result` for a nested type, or to `Module/Result`
    ///   for a top-level one.
    public static func colliding(
        in source: String, moduleName: String, names: Set<String>
    ) -> [String: String] {
        let tree = Parser.parse(source: source)
        let visitor = DeclarationVisitor(moduleName: moduleName, wanted: names)
        visitor.walk(tree)
        return visitor.found
    }

    /// Scans a package's sources for colliding declarations.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - names: Names worth looking for.
    /// - Returns: Bare name mapped to its qualified path.
    public static func colliding(projectRoot: String, names: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for spelling in ["Sources", "Source", "src"] {
            let root = URL(fileURLWithPath: projectRoot).appendingPathComponent(spelling)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = SourceFileReader.read(url, checker: "doc-lint") else { continue }
                let module = moduleName(of: url, spelling: spelling) ?? "Module"
                for (name, path) in colliding(in: text, moduleName: module, names: names) {
                    // First declaration wins, so the map is stable whatever order the
                    // file system hands the tree back in.
                    if result[name] == nil { result[name] = path }
                }
            }
        }
        return result
    }

    /// `Sources/<Module>/…` — the derivation used everywhere else in this package.
    static func moduleName(of file: URL, spelling: String) -> String? {
        let components = file.pathComponents
        guard let index = components.lastIndex(of: spelling), index + 1 < components.count else {
            return nil
        }
        return components[index + 1]
    }
}

/// Walks a file for type declarations, tracking what encloses them.
final class DeclarationVisitor: SyntaxVisitor {

    private(set) var found: [String: String] = [:]
    private var enclosing: [String] = []
    private let moduleName: String
    private let wanted: Set<String>

    init(moduleName: String, wanted: Set<String>) {
        self.moduleName = moduleName
        self.wanted = wanted
        super.init(viewMode: .sourceAccurate)
    }

    private func record(_ name: String) {
        guard wanted.contains(name), found[name] == nil else { return }
        // A nested type is qualified by what encloses it; a top-level one by its
        // module, which is what a reader has to write to disambiguate either way.
        let owner = enclosing.last ?? moduleName
        found[name] = "\(owner)/\(name)"
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text); enclosing.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { enclosing.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text); enclosing.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { enclosing.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text); enclosing.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { enclosing.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text); enclosing.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { enclosing.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text); enclosing.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { enclosing.removeLast() }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text); return .visitChildren
    }
}
