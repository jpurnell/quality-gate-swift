import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import RecursionAuditor

/// Temporary measurement harness for `ANameIsNotAnIdentity.md` §15.
///
/// Not a test of behaviour — it answers two questions the proposal blocks on, by
/// scanning the 22-package survey corpus. Delete once the answers are recorded.
/// Disabled by default: it scans a corpus outside this repository and takes ~150s.
/// Re-enable and run explicitly to reproduce the §15 numbers.
@Suite("Proposal measurements", .disabled("measurement harness — scans the local 22-package corpus"))
struct ProposalMeasurements {

    static let packages = [
        "SQLite.swift", "SwiftyJSON", "Alamofire", "swift-nio", "swift-collections",
        "swift-algorithms", "bitchat", "swift-url-routing", "swift-issue-reporting",
        "Ignite", "Ignite-upstream", "IceCubesApp", "Sitrep",
        "swift-composable-architecture", "swift-async-algorithms", "GRDB.swift",
        "Vortex", "Inferno", "Subsonic", "ControlRoom", "Unwrap", "SwiftGD",
    ]
    /// Override with `QG_CORPUS_ROOT` if the corpus lives elsewhere.
    static let root = ProcessInfo.processInfo.environment["QG_CORPUS_ROOT"]
        ?? "/Users/jpurnell/Dropbox/Computer/Development/Swift"

    static func swiftFiles(in package: String) -> [URL] {
        let base = URL(fileURLWithPath: "\(root)/\(package)")
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            let p = url.path
            if p.contains("/.build/") || p.contains("/.git/") { continue }
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    // MARK: - Normalization, as §3.1 proposes it

    static func normalize(_ type: String) -> String {
        var s = type.filter { !$0.isWhitespace }
        while let r = s.range(of: "Self.") { s.replaceSubrange(r, with: "") }
        var changed = true
        while changed {
            changed = false
            for (open, close, sep) in [("Array<", ">", ""), ("Optional<", ">", "")] {
                if let r = s.range(of: open), let end = matchingAngle(s, from: r.upperBound) {
                    let inner = String(s[r.upperBound..<end])
                    let replacement = open.hasPrefix("Array") ? "[\(inner)]" : "\(inner)?"
                    s.replaceSubrange(r.lowerBound..<s.index(after: end), with: replacement)
                    changed = true
                    _ = close; _ = sep
                    break
                }
            }
            if let r = s.range(of: "Dictionary<"), let end = matchingAngle(s, from: r.upperBound) {
                let inner = String(s[r.upperBound..<end])
                if let comma = topLevelComma(inner) {
                    let k = String(inner[inner.startIndex..<comma])
                    let v = String(inner[inner.index(after: comma)...])
                    s.replaceSubrange(r.lowerBound..<s.index(after: end), with: "[\(k):\(v)]")
                    changed = true
                }
            }
        }
        return s
    }

    static func matchingAngle(_ s: String, from: String.Index) -> String.Index? {
        var depth = 1
        var i = from
        while i < s.endIndex {
            if s[i] == "<" { depth += 1 }
            if s[i] == ">" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }

    static func topLevelComma(_ s: String) -> String.Index? {
        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<" || s[i] == "[" || s[i] == "(" { depth += 1 }
            if s[i] == ">" || s[i] == "]" || s[i] == ")" { depth -= 1 }
            if s[i] == "," && depth == 0 { return i }
            i = s.index(after: i)
        }
        return nil
    }

    struct Disc: Hashable {
        let params: [String]
        let isAsync: Bool
        let ret: String
    }

    static func discriminator(_ f: FunctionDeclSyntax) -> Disc {
        let params = f.signature.parameterClause.parameters.map {
            normalize($0.type.description)
        }
        let eff = f.signature.effectSpecifiers
        let ret = f.signature.returnClause.map { normalize($0.type.description) } ?? ""
        _ = eff?.throwsClause
        return Disc(params: params, isAsync: eff?.asyncSpecifier != nil, ret: ret)
    }

    static func displayName(_ f: FunctionDeclSyntax) -> String {
        let labels = f.signature.parameterClause.parameters.map {
            "\($0.firstName.text):"
        }.joined()
        return "\(f.name.text)(\(labels))"
    }

    // MARK: - M2: do requirement/default pairs collapse under normalization?

    @Test("M2: requirement and default discriminators")
    func measureRequirementDefaultCollapse() throws {
        var totalPairs = 0, mismatched = 0
        var examples: [String] = []

        for pkg in Self.packages {
            let files = Self.swiftFiles(in: pkg)
            guard !files.isEmpty else { continue }
            var requirements: [String: Set<Disc>] = [:]
            var defaults: [String: Set<Disc>] = [:]
            var protocolNames = Set<String>()

            var trees: [(URL, SourceFileSyntax)] = []
            for f in files {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                trees.append((f, Parser.parse(source: text)))
            }
            for (_, tree) in trees {
                for p in ProtocolFinder.find(tree) { protocolNames.insert(p) }
            }
            for (_, tree) in trees {
                let c = DeclCollector(protocolNames: protocolNames)
                c.walk(tree)
                for (k, v) in c.requirements { requirements[k, default: []].formUnion(v) }
                for (k, v) in c.defaults { defaults[k, default: []].formUnion(v) }
            }
            for (key, reqDiscs) in requirements {
                guard let defDiscs = defaults[key] else { continue }
                totalPairs += 1
                if reqDiscs.isDisjoint(with: defDiscs) {
                    mismatched += 1
                    if examples.count < 12 {
                        examples.append("  \(pkg): \(key)\n      req: \(reqDiscs.first.map(Self.describe) ?? "?")\n      def: \(defDiscs.first.map(Self.describe) ?? "?")")
                    }
                }
            }
        }

        print("=== M2: requirement/default pairs ===")
        print("pairs found: \(totalPairs)")
        print("discriminators DISAGREE (latent false negative): \(mismatched)")
        if totalPairs > 0 {
            let tenths = (mismatched * 1000) / totalPairs
            print("rate: \(tenths / 10).\(tenths % 10)%")
        }
        for e in examples { print(e) }

        // The measurement is only meaningful if it found the corpus at all: a run over an
        // absent corpus reports zero disagreements, which reads exactly like success.
        #expect(totalPairs > 0, "no requirement/default pairs found — is the corpus present?")
        // §15's claim, pinned: after normalization, every remaining disagreement is a
        // genuinely distinct overload rather than a spelling difference. Measured 5 of 229.
        #expect(mismatched * 20 <= totalPairs, "normalization regressed beyond 5% of pairs")
    }

    static func describe(_ d: Disc) -> String {
        "(\(d.params.joined(separator: ", ")))\(d.isAsync ? " async" : "") -> \(d.ret.isEmpty ? "Void" : d.ret)"
    }

    // MARK: - M1: how common is synchronous-closure self-reference?

    @Test("M1: closure-contained self-references")
    func measureClosureContainedSelfReference() throws {
        var byCallee: [String: Int] = [:]
        var totalDemoted = 0
        var examples: [String] = []

        for pkg in Self.packages {
            for f in Self.swiftFiles(in: pkg) {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let tree = Parser.parse(source: text)
                let v = ClosureSelfRefFinder()
                v.walk(tree)
                for hit in v.hits {
                    totalDemoted += 1
                    byCallee[hit.callee, default: 0] += 1
                    if examples.count < 15 {
                        examples.append("  \(pkg): \(hit.owner) -> passed to '\(hit.callee)'")
                    }
                }
            }
        }

        print("=== M1: declarations whose ONLY self-reference is closure-enclosed ===")
        print("total: \(totalDemoted)")
        print("--- by receiving function ---")
        for (callee, n) in byCallee.sorted(by: { $0.value > $1.value }) {
            print("  \(n)  \(callee)")
        }
        for e in examples { print(e) }

        #expect(totalDemoted > 0, "no closure-contained self-references found — is the corpus present?")
        // §15's finding, pinned: the population RC3 would have demoted is dominated by
        // closures that run synchronously, so a syntactic demotion is not worth having.
        let deferring = ["async", "Task", "execute", "scheduleTask", "whenComplete"]
        let deferred = byCallee.filter { deferring.contains($0.key) }.values.reduce(0, +)
        #expect(deferred * 4 < totalDemoted, "deferred share rose above 25% — revisit RC3")
    }
}

// MARK: - Visitors

final class ProtocolFinder: SyntaxVisitor {
    var names: [String] = []
    static func find(_ tree: SourceFileSyntax) -> [String] {
        let f = ProtocolFinder(viewMode: .sourceAccurate); f.walk(tree); return f.names
    }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        names.append(node.name.text); return .visitChildren
    }
}

final class DeclCollector: SyntaxVisitor {
    let protocolNames: Set<String>
    var requirements: [String: Set<ProposalMeasurements.Disc>] = [:]
    var defaults: [String: Set<ProposalMeasurements.Disc>] = [:]

    init(protocolNames: Set<String>) {
        self.protocolNames = protocolNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        for m in node.memberBlock.members {
            guard let f = m.decl.as(FunctionDeclSyntax.self), f.body == nil else { continue }
            let key = "\(node.name.text).\(ProposalMeasurements.displayName(f))"
            requirements[key, default: []].insert(ProposalMeasurements.discriminator(f))
        }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.extendedType.trimmedDescription
        guard protocolNames.contains(typeName) else { return .visitChildren }
        for m in node.memberBlock.members {
            guard let f = m.decl.as(FunctionDeclSyntax.self), f.body != nil else { continue }
            let key = "\(typeName).\(ProposalMeasurements.displayName(f))"
            defaults[key, default: []].insert(ProposalMeasurements.discriminator(f))
        }
        return .visitChildren
    }
}

/// Finds declarations whose self-references all sit inside a closure — the population
/// §3.3 would demote — and records which function each closure is handed to.
final class ClosureSelfRefFinder: SyntaxVisitor {
    struct Hit { let owner: String; let callee: String }
    var hits: [Hit] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let body = node.body else { return .visitChildren }
        check(name: node.name.text, body: Syntax(body), owner: "func \(node.name.text)")
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for b in node.bindings {
            guard let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let accessors = b.accessorBlock else { continue }
            check(name: name, body: Syntax(accessors), owner: "var \(name)")
        }
        return .visitChildren
    }

    private func check(name: String, body: Syntax, owner: String) {
        let refs = ReferenceFinder.find(in: body, name: name)
        guard !refs.isEmpty else { return }
        var callees: [String] = []
        for r in refs {
            guard let closure = enclosingClosure(of: r, within: body) else { return } // a bare ref: not demoted
            callees.append(receivingFunction(of: closure) ?? "<unknown>")
        }
        for c in callees { hits.append(Hit(owner: owner, callee: c)) }
    }

    private func enclosingClosure(of node: Syntax, within body: Syntax) -> ClosureExprSyntax? {
        var cur: Syntax? = node.parent
        while let c = cur, c.id != body.id {
            if let cl = c.as(ClosureExprSyntax.self) { return cl }
            cur = c.parent
        }
        return nil
    }

    private func receivingFunction(of closure: ClosureExprSyntax) -> String? {
        var cur: Syntax? = closure.parent
        while let c = cur {
            if let call = c.as(FunctionCallExprSyntax.self) {
                let callee = call.calledExpression
                if let m = callee.as(MemberAccessExprSyntax.self) { return m.declName.baseName.text }
                if let d = callee.as(DeclReferenceExprSyntax.self) { return d.baseName.text }
                return "<expr>"
            }
            if c.is(ClosureExprSyntax.self) { return nil }
            cur = c.parent
        }
        return nil
    }
}

final class ReferenceFinder: SyntaxVisitor {
    let target: String
    var found: [Syntax] = []
    init(target: String) { self.target = target; super.init(viewMode: .sourceAccurate) }

    static func find(in body: Syntax, name: String) -> [Syntax] {
        let f = ReferenceFinder(target: name); f.walk(body); return f.found
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if node.baseName.text == target { found.append(Syntax(node)) }
        return .visitChildren
    }
}
