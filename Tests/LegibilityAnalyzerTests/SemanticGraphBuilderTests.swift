import Foundation
import Testing
@testable import LegibilityAnalyzer

@Suite("SemanticGraphBuilder")
struct SemanticGraphBuilderTests {

    @Test("cross-module references become weighted directed edges")
    func crossModuleEdges() {
        let refs = [
            ReferenceFact(defUSR: "Foo", defModule: "Core", refModule: "App"),
            ReferenceFact(defUSR: "Foo", defModule: "Core", refModule: "App"),
        ]
        let facts = SemanticGraphBuilder.build(references: refs, publicUSRs: [])
        // App depends on Core; Core is relied on by App.
        #expect(facts.graph.dependencies(of: "App") == ["Core"])
        #expect(facts.graph.fanIn("Core") == 1)
        #expect(facts.graph.weightedFanIn("Core") == 2)
    }

    @Test("in-module references do not create edges")
    func inModuleNoEdge() {
        let refs = [ReferenceFact(defUSR: "Bar", defModule: "Core", refModule: "Core")]
        let facts = SemanticGraphBuilder.build(references: refs, publicUSRs: [])
        #expect(facts.graph.edges.isEmpty)
    }

    @Test("a public symbol referenced only in-module is over-public")
    func overPublicInModuleOnly() {
        let refs = [ReferenceFact(defUSR: "Bar", defModule: "Core", refModule: "Core")]
        let facts = SemanticGraphBuilder.build(references: refs, publicUSRs: ["Bar"])
        #expect(facts.overPublicUSRs == ["Bar"])
    }

    @Test("a public symbol referenced cross-module is not over-public")
    func crossModuleNotOverPublic() {
        let refs = [ReferenceFact(defUSR: "Foo", defModule: "Core", refModule: "App")]
        let facts = SemanticGraphBuilder.build(references: refs, publicUSRs: ["Foo"])
        #expect(facts.overPublicUSRs.isEmpty)
    }

    @Test("a public symbol with no references is not over-public (that is dead code)")
    func deadNotOverPublic() {
        let facts = SemanticGraphBuilder.build(references: [], publicUSRs: ["Baz"])
        #expect(facts.overPublicUSRs.isEmpty)
        #expect(!facts.referencedUSRs.contains("Baz"))
    }

    @Test("a non-public in-module symbol is never over-public")
    func nonPublicNotOverPublic() {
        let refs = [ReferenceFact(defUSR: "Internal", defModule: "Core", refModule: "Core")]
        let facts = SemanticGraphBuilder.build(references: refs, publicUSRs: [])
        #expect(facts.overPublicUSRs.isEmpty)
    }

    @Test("mixed graph resolves edges, over-public, and referenced set together")
    func mixedScenario() {
        let refs = [
            ReferenceFact(defUSR: "Foo", defModule: "Core", refModule: "App"),
            ReferenceFact(defUSR: "Foo", defModule: "Core", refModule: "App"),
            ReferenceFact(defUSR: "Bar", defModule: "Core", refModule: "Core"),
        ]
        let facts = SemanticGraphBuilder.build(
            references: refs,
            publicUSRs: ["Foo", "Bar", "Baz"]
        )
        #expect(facts.graph.weightedFanIn("Core") == 2)
        #expect(facts.overPublicUSRs == ["Bar"])            // in-module only
        #expect(facts.referencedUSRs == ["Foo", "Bar"])     // Baz never referenced
    }
}
