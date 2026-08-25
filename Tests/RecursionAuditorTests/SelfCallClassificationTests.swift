import Foundation
import Testing
import QualityGateCore
@testable import RecursionAuditor

/// `ProvisionalByConstruction.md`: Pass 2 classifies a USR self-edge by the index's
/// symbol name and emits Pass 1's rule vocabulary at Pass 1's severities, and the
/// superseded set is derived from that classifier rather than maintained beside it.
@Suite("Self-call classification — Pass 2 vocabulary")
struct SelfCallClassificationTests {

    /// A single-node self-loop for `name`, analysed and with no self-base-case.
    private func makeSelfLoop(name: String) -> USRCallGraph {
        let graph = USRCallGraph()
        graph.addEdge(from: "usr:x", to: "usr:x")
        graph.setSymbolInfo("usr:x", info: SymbolInfo(
            displayName: name, filePath: "/p/A.swift", line: 5, column: 5, moduleName: "M"))
        graph.markAnalysed("usr:x")
        return graph
    }

    private func onlyDiagnostic(_ graph: USRCallGraph) -> Diagnostic? {
        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
            .filter { $0.severity != .note }
        return diagnostics.count == 1 ? diagnostics.first : nil
    }

    @Test("a getter self-edge is a computed-property-self error")
    func getterSelfEdge() throws {
        let diagnostic = try #require(onlyDiagnostic(makeSelfLoop(name: "getter:v")))
        #expect(diagnostic.ruleId == "recursion.computed-property-self")
        #expect(diagnostic.severity == .error)
    }

    @Test("a setter self-edge is a setter-self error")
    func setterSelfEdge() throws {
        let diagnostic = try #require(onlyDiagnostic(makeSelfLoop(name: "setter:v")))
        #expect(diagnostic.ruleId == "recursion.setter-self")
        #expect(diagnostic.severity == .error)
    }

    @Test("a subscript getter self-edge is a subscript-self error")
    func subscriptGetterSelfEdge() throws {
        let diagnostic = try #require(onlyDiagnostic(makeSelfLoop(name: "getter:subscript(_:)")))
        #expect(diagnostic.ruleId == "recursion.subscript-self")
        #expect(diagnostic.severity == .error)
    }

    @Test("a subscript setter self-edge is a subscript-setter-self error")
    func subscriptSetterSelfEdge() throws {
        let diagnostic = try #require(onlyDiagnostic(makeSelfLoop(name: "setter:subscript(key:)")))
        #expect(diagnostic.ruleId == "recursion.subscript-setter-self")
        #expect(diagnostic.severity == .error)
    }

    @Test("an initializer self-edge is a convenience-init-self error")
    func initializerSelfEdge() throws {
        let diagnostic = try #require(onlyDiagnostic(makeSelfLoop(name: "init(y:)")))
        #expect(diagnostic.ruleId == "recursion.convenience-init-self")
        #expect(diagnostic.severity == .error)
    }

    @Test("a plain function self-edge stays an unconditional-self-call warning")
    func functionSelfEdge() throws {
        let diagnostic = try #require(onlyDiagnostic(makeSelfLoop(name: "recurse(depth:)")))
        #expect(diagnostic.ruleId == "recursion.unconditional-self-call")
        #expect(diagnostic.severity == .warning)
    }

    @Test("a self-base-case suppresses every classification")
    func selfBaseCaseSuppresses() {
        for name in ["getter:v", "setter:v", "init(y:)", "recurse()"] {
            let graph = makeSelfLoop(name: name)
            graph.markHasSelfBaseCase("usr:x")
            let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
                .filter { $0.severity != .note }
            #expect(diagnostics.isEmpty, "\(name) should be suppressed by its base case")
        }
    }

    @Test("an unanalysed symbol is never judged, whatever its shape")
    func unanalysedSuppresses() {
        let graph = USRCallGraph()
        graph.addEdge(from: "usr:x", to: "usr:x")
        graph.setSymbolInfo("usr:x", info: SymbolInfo(
            displayName: "getter:v", filePath: "/p/A.swift", line: 5, column: 5, moduleName: "M"))
        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
            .filter { $0.severity != .note }
        #expect(diagnostics.isEmpty)
    }

    @Test("the superseded set is derived: every classifier rule id is in it")
    func supersededSetIsDerived() {
        let superseded = RecursionIndexPass.supersededByUSR
        for ruleId in [
            "recursion.unconditional-self-call",
            "recursion.computed-property-self",
            "recursion.setter-self",
            "recursion.subscript-self",
            "recursion.subscript-setter-self",
            "recursion.convenience-init-self",
            "recursion.mutual-cycle",
            "recursion.protocol-extension-default-self",
            "recursion.self-reference-unresolved",
        ] {
            #expect(superseded.contains(ruleId), "\(ruleId) missing from the superseded set")
        }
    }
}

@Suite("Initializer declarations join the site handoff")
struct InitializerDeclarationInfoTests {

    @Test("analyzeInitializer records a DeclarationInfo with the index's naming")
    func initializerYieldsDeclarationInfo() throws {
        let analysis = analyzeSourceForTesting("""
        struct S {
            var stored: Int
            init(y: Int) {
                self.init(y: y)
            }
        }
        """)
        let initDecl = try #require(
            analysis.declarations.first { $0.signature.displayName == "init(y:)" })
        #expect(initDecl.wasAnalysed == true)
        #expect(initDecl.hasSelfBaseCase == false)
        #expect(initDecl.signature.typeContext == "S")
    }

    @Test("an initializer with a non-delegating branch has a self base case")
    func initializerBaseCase() {
        let analysis = analyzeSourceForTesting("""
        struct S {
            var stored: Int
            init(y: Int) {
                guard y > 0 else { self.stored = 0; return }
                self.init(y: y - 1)
            }
        }
        """)
        let initDecl = analysis.declarations.first { $0.signature.displayName == "init(y:)" }
        #expect(initDecl?.hasSelfBaseCase == true)
    }
}
