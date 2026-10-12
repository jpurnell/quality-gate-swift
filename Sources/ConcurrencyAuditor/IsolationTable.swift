import SwiftSyntax

/// What one type declaration says about itself: its isolation and its stored state.
struct TypeFacts: Equatable {
    /// `.mainActor`, `.actor(name:)`, or `.none` — read from the declaration alone.
    let isolation: IsolationContext
    /// The declaration's instance stored properties (`collectStoredProperties`).
    let storedProperties: Set<String>
    /// The file the declaration was found in.
    let file: String
}

/// Every type declaration in a run, keyed so an extension can find the type it extends.
///
/// An extension carries no isolation of its own: `extension Model { … }` is main-actor
/// code when `Model` is `@MainActor`, and the only place that is written is `Model`'s
/// declaration — often in another file. This table is the pre-pass that reads those
/// declarations before the per-file walk needs them.
///
/// Types are looked up by **name**, inside a **module bucket** (the directory under
/// `Sources/`, `Tests/` or `Plugins/`). That is a guess at what the compiler knows
/// exactly, so the table answers only when the guess cannot be wrong in the direction
/// that matters: it refuses when declarations under one name disagree, and it never
/// looks in a bucket the asking file does not import. Refusing means the extension is
/// treated as non-isolated, which reports nothing.
///
/// See `quality-gate-swift-project/plans/proposals/AnExtensionInheritsIsolation.md`.
struct IsolationTable {
    /// module bucket → qualified type name → every declaration found under that name.
    private(set) var facts: [String: [String: [TypeFacts]]] = [:]
    /// file → the modules it imports.
    private(set) var imports: [String: Set<String>] = [:]
    /// file → its module bucket.
    private(set) var buckets: [String: String] = [:]

    /// Adds one parsed file to the table.
    ///
    /// - Parameters:
    ///   - tree: The file's syntax tree.
    ///   - file: The path the per-file walk will use for the same file.
    ///   - root: The project root, for working out the module bucket. Empty when the
    ///     path is already relative.
    mutating func add(_ tree: SourceFileSyntax, file: String, root: String = "") {
        let bucket = Self.moduleBucket(ofFile: file, root: root)
        let collector = Collector(file: file)
        collector.walk(tree)
        buckets[file] = bucket
        imports[file] = collector.imports
        for (name, declared) in collector.declarations {
            facts[bucket, default: [:]][name, default: []].append(contentsOf: declared)
        }
    }

    /// The facts for the type an extension in `file` extends, or `nil` when the table
    /// cannot say: the type is declared somewhere the run did not read, in a module the
    /// file does not import, or under a name whose declarations disagree.
    func resolve(_ extendedType: TypeSyntax, fromFile file: String) -> TypeFacts? {
        resolve(typeName: Self.normalisedName(of: extendedType), fromFile: file)
    }

    /// As ``resolve(_:fromFile:)``, for a name already normalised.
    func resolve(typeName: String, fromFile file: String) -> TypeFacts? {
        guard !typeName.isEmpty else { return nil }
        let own = buckets[file] ?? ""
        let imported = (imports[file] ?? []).subtracting([own])

        // 1. The file's own module decides, if it declares the name at all.
        if let declared = facts[own]?[typeName], !declared.isEmpty {
            return Self.agreed(declared)
        }
        // 2. Otherwise the modules it imports, taken together.
        let fromImports = imported.sorted().flatMap { facts[$0]?[typeName] ?? [] }
        if !fromImports.isEmpty {
            return Self.agreed(fromImports)
        }
        // 3. `Module.Type`, where `Module` is the file's own or one it imports.
        let parts = typeName.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0] == own || imported.contains(parts[0]),
              let declared = facts[parts[0]]?[parts[1]], !declared.isEmpty else {
            return nil
        }
        return Self.agreed(declared)
    }

    /// One answer for several declarations of a name, or `nil` if they disagree on
    /// isolation. Stored properties are the union.
    private static func agreed(_ declared: [TypeFacts]) -> TypeFacts? {
        guard let first = declared.first else { return nil }
        guard declared.allSatisfy({ $0.isolation == first.isolation }) else { return nil }
        let properties = declared.reduce(into: Set<String>()) { $0.formUnion($1.storedProperties) }
        return TypeFacts(isolation: first.isolation, storedProperties: properties, file: first.file)
    }

    /// The extended type's name with whitespace and generic arguments dropped:
    /// `Box<Int>` → `Box`, `Outer.Inner<T>` → `Outer.Inner`.
    static func normalisedName(of type: TypeSyntax) -> String {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            let base = normalisedName(of: member.baseType)
            return base.isEmpty ? member.name.text : base + "." + member.name.text
        }
        return ""
    }

    /// The module a file belongs to, by SwiftPM's directory convention: the path
    /// component after `Sources/`, `Tests/` or `Plugins/`. A file directly inside one of
    /// those is bucketed under that directory's name, and a file in any other layout
    /// under its first path component.
    ///
    /// This is a heuristic. Its failure mode is two targets sharing a bucket, where a
    /// disagreement between them resolves to "unknown"; it cannot produce isolation that
    /// no declaration states.
    static func moduleBucket(ofFile file: String, root: String) -> String {
        // Compared component by component: a path under `root` is one whose leading
        // components are `root`'s, which a string-prefix test does not establish.
        var components = file.split(separator: "/").map(String.init)
        let rootComponents = root.split(separator: "/").map(String.init)
        if !rootComponents.isEmpty, Array(components.prefix(rootComponents.count)) == rootComponents {
            components.removeFirst(rootComponents.count)
        }
        let directories = components.dropLast()
        let markers: Set<String> = ["Sources", "Tests", "Plugins"]
        if let marker = directories.firstIndex(where: { markers.contains($0) }) {
            let next = directories.index(after: marker)
            return next < directories.endIndex ? directories[next] : directories[marker]
        }
        return directories.first ?? ""
    }
}

// MARK: - Collector

/// Collects a file's type declarations, under their qualified names, and its imports.
private final class Collector: SyntaxVisitor {
    let file: String
    private(set) var declarations: [String: [TypeFacts]] = [:]
    private(set) var imports: Set<String> = []
    /// Names of the enclosing types and extensions, outermost first.
    private var nesting: [String] = []

    init(file: String) {
        self.file = file
        super.init(viewMode: .sourceAccurate)
    }

    private func record(name: String, isolation: IsolationContext, members: MemberBlockSyntax?) {
        let qualified = (nesting + [name]).joined(separator: ".")
        let properties = members.map { collectStoredProperties(memberBlock: $0) } ?? []
        declarations[qualified, default: []].append(
            TypeFacts(isolation: isolation, storedProperties: properties, file: file))
        nesting.append(name)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let module = node.path.first?.name.text { imports.insert(module) }
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let isolation: IsolationContext = hasMainActorAttribute(node.attributes) ? .mainActor : .none
        record(name: node.name.text, isolation: isolation, members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { nesting.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let isolation: IsolationContext = hasMainActorAttribute(node.attributes) ? .mainActor : .none
        record(name: node.name.text, isolation: isolation, members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { nesting.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let isolation: IsolationContext = hasMainActorAttribute(node.attributes) ? .mainActor : .none
        record(name: node.name.text, isolation: isolation, members: nil)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { nesting.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, isolation: .actor(name: node.name.text), members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { nesting.removeLast() }

    /// A type declared inside an extension is qualified by the extended type.
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        nesting.append(IsolationTable.normalisedName(of: node.extendedType))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { nesting.removeLast() }
}
