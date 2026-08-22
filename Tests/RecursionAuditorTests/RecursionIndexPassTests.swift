import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

@Suite("RecursionIndexPass Tests")
struct RecursionIndexPassTests {

    // MARK: - Tarjan SCC Algorithm

    @Test("Tarjan SCC finds a simple 2-node cycle")
    func tarjanFindsSimpleCycle() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:4test1ayyF", to: "s:4test1byyF")
        graph.addEdge(from: "s:4test1byyF", to: "s:4test1ayyF")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.count == 1)
        #expect(cyclicSCCs[0].count == 2)
    }

    @Test("Tarjan SCC finds a 3-node cycle")
    func tarjanFindsThreeNodeCycle() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:4test1ayyF", to: "s:4test1byyF")
        graph.addEdge(from: "s:4test1byyF", to: "s:4test1cyyF")
        graph.addEdge(from: "s:4test1cyyF", to: "s:4test1ayyF")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.count == 1)
        #expect(cyclicSCCs[0].count == 3)
    }

    @Test("Tarjan SCC returns singleton for non-cyclic node")
    func tarjanNoCycle() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:4test1ayyF", to: "s:4test1byyF")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.isEmpty)
    }

    @Test("Tarjan SCC handles multiple independent cycles")
    func tarjanMultipleCycles() {
        let graph = USRCallGraph()
        graph.addEdge(from: "usr:a", to: "usr:b")
        graph.addEdge(from: "usr:b", to: "usr:a")
        graph.addEdge(from: "usr:c", to: "usr:d")
        graph.addEdge(from: "usr:d", to: "usr:c")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.count == 2)
    }

    @Test("Tarjan SCC handles self-loop")
    func tarjanSelfLoop() {
        let graph = USRCallGraph()
        graph.addEdge(from: "usr:a", to: "usr:a")

        let sccs = graph.findStronglyConnectedComponents()
        let selfLoops = sccs.filter { component in
            component.count == 1 && graph.hasSelfEdge(component.first ?? "")
        }
        #expect(selfLoops.count == 1)
    }

    @Test("Tarjan SCC handles empty graph")
    func tarjanEmptyGraph() {
        let graph = USRCallGraph()
        let sccs = graph.findStronglyConnectedComponents()
        #expect(sccs.isEmpty)
    }

    @Test("Tarjan SCC handles isolated nodes with no edges")
    func tarjanIsolatedNodes() {
        let graph = USRCallGraph()
        graph.addNode("usr:a")
        graph.addNode("usr:b")
        graph.addNode("usr:c")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.isEmpty)
    }

    // MARK: - Scale

    @Test("Tarjan SCC handles 1000-node linear chain without cycles")
    func tarjanScaleLinearChain() {
        let graph = USRCallGraph()
        for i in 0..<1000 {
            graph.addEdge(from: "usr:node\(i)", to: "usr:node\(i + 1)")
        }

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.isEmpty)
    }

    @Test("Tarjan SCC handles 1000-node ring cycle")
    func tarjanScaleRingCycle() {
        let graph = USRCallGraph()
        let nodeCount = 1000
        for i in 0..<nodeCount {
            graph.addEdge(from: "usr:node\(i)", to: "usr:node\((i + 1) % nodeCount)")
        }

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.count == 1)
        #expect(cyclicSCCs[0].count == nodeCount)
    }

    // MARK: - USR-based name collision elimination

    @Test("USR-based graph distinguishes overloaded methods with same display name")
    func usrDistinguishesOverloads() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:6ModuleA1AV7processyyF", to: "s:6ModuleB1BV7processyyF")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.isEmpty)
    }

    // MARK: - Cross-module cycle detection

    @Test("Detects cross-module mutual recursion cycle")
    func crossModuleCycleDetection() {
        let graph = USRCallGraph()
        let usrA = "s:7ModuleA4funcyyF"
        let usrB = "s:7ModuleB4funcyyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrA)
        graph.setModuleName(usrA, module: "ModuleA")
        graph.setModuleName(usrB, module: "ModuleB")

        let sccs = graph.findStronglyConnectedComponents()
        let crossModuleCycles = sccs.filter { $0.count >= 2 && graph.isCrossModule($0) }
        #expect(crossModuleCycles.count == 1)
    }

    @Test("Same-module cycle is not flagged as cross-module")
    func sameModuleCycleNotCrossModule() {
        let graph = USRCallGraph()
        let usrA = "s:7ModuleA1ayyF"
        let usrB = "s:7ModuleA1byyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrA)
        graph.setModuleName(usrA, module: "ModuleA")
        graph.setModuleName(usrB, module: "ModuleA")

        let sccs = graph.findStronglyConnectedComponents()
        let crossModuleCycles = sccs.filter { $0.count >= 2 && graph.isCrossModule($0) }
        #expect(crossModuleCycles.isEmpty)
    }

    // MARK: - Protocol witness cycle detection

    @Test("Detects protocol witness cycle pattern")
    func protocolWitnessCycle() {
        let graph = USRCallGraph()
        let usrDefaultFoo = "s:7ModuleP1PE3fooyyF"
        let usrBar = "s:7ModuleP12ConcreteTypeV3baryyF"
        let usrWitnessFoo = "s:7ModuleP12ConcreteTypeV3fooyyF"
        graph.addEdge(from: usrDefaultFoo, to: usrBar)
        graph.addEdge(from: usrBar, to: usrWitnessFoo)
        graph.addEdge(from: usrWitnessFoo, to: usrDefaultFoo)
        graph.markAsProtocolWitness(usrWitnessFoo)
        graph.markAsDefaultImplementation(usrDefaultFoo)

        let sccs = graph.findStronglyConnectedComponents()
        let witnessCycles = sccs.filter { $0.count >= 2 && graph.isProtocolWitnessCycle($0) }
        #expect(witnessCycles.count == 1)
    }

    @Test("Normal protocol conformance without cycle is not flagged")
    func normalProtocolConformanceNoCycle() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:Concrete3fooyyF", to: "s:P3fooyyF")
        graph.markAsProtocolWitness("s:Concrete3fooyyF")
        graph.markAsDefaultImplementation("s:P3fooyyF")

        let sccs = graph.findStronglyConnectedComponents()
        let witnessCycles = sccs.filter { $0.count >= 2 && graph.isProtocolWitnessCycle($0) }
        #expect(witnessCycles.isEmpty)
    }

    // MARK: - Diagnostic generation

    @Test("Cross-module cycle diagnostic uses correct rule ID")
    func crossModuleCycleDiagnosticRuleId() {
        let graph = USRCallGraph()
        let usrA = "s:7ModuleA4funcyyF"
        let usrB = "s:7ModuleB4funcyyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrA)
        graph.setModuleName(usrA, module: "ModuleA")
        graph.setModuleName(usrB, module: "ModuleB")
        graph.setSymbolInfo(usrA, info: SymbolInfo(displayName: "func()", filePath: "A.swift", line: 1, column: 1, moduleName: "ModuleA"))
        graph.setSymbolInfo(usrB, info: SymbolInfo(displayName: "func()", filePath: "B.swift", line: 1, column: 1, moduleName: "ModuleB"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        let crossModuleDiags = diagnostics.filter { $0.ruleId == "recursion.cross-module-cycle" }
        #expect(crossModuleDiags.count >= 2)
        // Error, not warning: an unbounded cycle is a crash on untrusted input, and a
        // stack overflow cannot be caught by the caller. Promoted in the fix for
        // `UnboundedRecursionIsAnError.md`, where four correct findings sat unread
        // because the severity told the reader not to care.
        #expect(crossModuleDiags.allSatisfy { $0.severity == .error })
    }

    @Test("Protocol witness cycle diagnostic uses correct rule ID")
    func protocolWitnessCycleDiagnosticRuleId() {
        let graph = USRCallGraph()
        let usrA = "s:P3defaultFooyyF"
        let usrB = "s:Concrete3baryyF"
        let usrC = "s:Concrete3fooyyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrC)
        graph.addEdge(from: usrC, to: usrA)
        graph.markAsDefaultImplementation(usrA)
        graph.markAsProtocolWitness(usrC)
        graph.setModuleName(usrA, module: "M")
        graph.setModuleName(usrB, module: "M")
        graph.setModuleName(usrC, module: "M")
        graph.setSymbolInfo(usrA, info: SymbolInfo(displayName: "foo()", filePath: "P.swift", line: 1, column: 1, moduleName: "M"))
        graph.setSymbolInfo(usrB, info: SymbolInfo(displayName: "bar()", filePath: "C.swift", line: 1, column: 1, moduleName: "M"))
        graph.setSymbolInfo(usrC, info: SymbolInfo(displayName: "foo()", filePath: "C.swift", line: 5, column: 1, moduleName: "M"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        let witnessDiags = diagnostics.filter { $0.ruleId == "recursion.protocol-witness-cycle" }
        #expect(!witnessDiags.isEmpty)
        // Error, not warning: an unbounded cycle is a crash on untrusted input, and a
        // stack overflow cannot be caught by the caller. Promoted in the fix for
        // `UnboundedRecursionIsAnError.md`, where four correct findings sat unread
        // because the severity told the reader not to care.
        #expect(witnessDiags.allSatisfy { $0.severity == .error })
    }

    // MARK: - Graceful degradation

    @Test("Pass 2 gracefully skips when index is unavailable")
    func gracefulDegradationNoIndex() {
        let result = RecursionIndexPass.runWithoutIndex()
        #expect(result.count == 1)
        #expect(result[0].severity == .note)
        #expect(result[0].ruleId == "recursion.index_pass.skipped")
    }

    // MARK: - Configuration

    @Test("RecursionAuditorConfig defaults to useIndexStore true")
    func configDefaultsToTrue() {
        let config = RecursionAuditorConfig()
        #expect(config.useIndexStore == true)
    }

    @Test("Configuration includes recursion config")
    func configurationIncludesRecursion() {
        let config = Configuration()
        #expect(config.recursion.useIndexStore == true)
    }

    // MARK: - Severity demotion

    @Test("Name-based mutual cycle is demoted to note when Pass 2 runs")
    func nameBasedFallbackDemotedToNote() {
        let nameBasedDiag = Diagnostic(
            severity: .warning,
            message: "function 'a()' participates in a mutual recursion cycle with no base case",
            filePath: "A.swift",
            lineNumber: 1,
            columnNumber: 1,
            ruleId: "recursion.mutual-cycle",
            suggestedFix: "Add a guard-driven base case."
        )

        let demoted = RecursionIndexPass.demoteToNote(nameBasedDiag)
        #expect(demoted.severity == .note)
        #expect(demoted.ruleId == "recursion.mutual-cycle")
        #expect(demoted.message.contains("name-based"))
    }

    // MARK: - Base case filtering

    @Test("Cycle with base case is not flagged")
    func cycleWithBaseCaseNotFlagged() {
        let graph = USRCallGraph()
        let usrA = "s:M1ayyF"
        let usrB = "s:M1byyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrA)
        graph.setModuleName(usrA, module: "M")
        graph.setModuleName(usrB, module: "M")
        graph.setSymbolInfo(usrA, info: SymbolInfo(displayName: "a()", filePath: "A.swift", line: 1, column: 1, moduleName: "M"))
        graph.setSymbolInfo(usrB, info: SymbolInfo(displayName: "b()", filePath: "B.swift", line: 1, column: 1, moduleName: "M"))
        graph.markHasBaseCase(usrA)

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        let cycleDiags = diagnostics.filter { $0.ruleId == "recursion.mutual-cycle" }
        #expect(cycleDiags.isEmpty)
    }

    // MARK: - Carrying Pass 1's base-case knowledge into Pass 2

    @Test("Base-case sites come only from callable declarations that have one")
    func baseCaseSitesFilterCorrectly() {
        func declaration(_ name: String, hasBaseCase: Bool, isCallable: Bool) -> DeclarationInfo {
            DeclarationInfo(
                signature: Signature(typeContext: "T", displayName: name),
                location: SourceLocation(file: "/Users/example/A.swift", line: 1, column: 1),
                hasBaseCase: hasBaseCase,
                hasSelfBaseCase: hasBaseCase,
                wasAnalysed: true,
                outgoingCalls: [],
                isCallable: isCallable
            )
        }
        let sites = RecursionIndexPass.baseCaseSites(from: [
            declaration("bounded()", hasBaseCase: true, isCallable: true),
            declaration("unbounded()", hasBaseCase: false, isCallable: true),
            declaration("property", hasBaseCase: true, isCallable: false),
        ])
        let path = "/Users/example/A.swift"
        #expect(sites.contains(DeclarationSite(path: path, name: "bounded()")))
        #expect(!sites.contains(DeclarationSite(path: path, name: "unbounded()")))
        #expect(!sites.contains(DeclarationSite(path: path, name: "property")))
        #expect(sites.count == 1)
    }

    @Test("A cycle whose participant has a base case is not reported")
    func cycleWithBaseCaseIsNotReported() {
        // The property `scanForBaseCases` established textually, now established from
        // the AST pass instead — and for base cases a text scan for "guard " cannot
        // see, such as a bare return.
        let graph = USRCallGraph()
        let a = "s:1M1ayyF", b = "s:1M1byyF"
        graph.addEdge(from: a, to: b)
        graph.addEdge(from: b, to: a)
        graph.markHasBaseCase(a)
        graph.setModuleName(a, module: "M")
        graph.setModuleName(b, module: "M")
        graph.setSymbolInfo(a, info: SymbolInfo(displayName: "a()", filePath: "A.swift", line: 1, column: 1, moduleName: "M"))
        graph.setSymbolInfo(b, info: SymbolInfo(displayName: "b()", filePath: "A.swift", line: 5, column: 1, moduleName: "M"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        #expect(!diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }


    // MARK: - Direct self-recursion (single-node components)

    @Test("An unbounded self-edge is reported")
    func unboundedSelfEdgeIsReported() {
        // Tarjan reports direct recursion as a one-node component, and the cycle loop
        // requires two or more participants, so nothing looked at self-calls. That was
        // tolerable while the AST pass reported every self-call it could name; it stops
        // being tolerable once that pass defers overloaded signatures here.
        let graph = USRCallGraph()
        let usr = "s:1M6EncoderV6encodeyySiF"
        graph.addEdge(from: usr, to: usr)
        graph.markAnalysed(usr)  // a real function body the AST pass read
        graph.setModuleName(usr, module: "M")
        graph.setSymbolInfo(usr, info: SymbolInfo(displayName: "encode(_:)", filePath: "E.swift", line: 3, column: 5, moduleName: "M"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        #expect(diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("A self-edge with a self base case is not reported")
    func selfEdgeWithSelfBaseCaseIsNotReported() {
        // The loose test, not the strict one a cycle needs: any branch that does not
        // re-enter *this* function bounds direct recursion, whatever it returns.
        let graph = USRCallGraph()
        let usr = "s:1M4FactV7computeySiSiF"
        graph.addEdge(from: usr, to: usr)
        graph.markHasSelfBaseCase(usr)
        graph.setModuleName(usr, module: "M")
        graph.setSymbolInfo(usr, info: SymbolInfo(displayName: "compute(_:)", filePath: "F.swift", line: 2, column: 5, moduleName: "M"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        #expect(!diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("A node with no self-edge is not reported as self-recursive")
    func nonRecursiveNodeIsNotReported() {
        let graph = USRCallGraph()
        let usr = "s:1M5PlainV4stepyyF"
        graph.addNode(usr)
        graph.setModuleName(usr, module: "M")
        graph.setSymbolInfo(usr, info: SymbolInfo(displayName: "step()", filePath: "P.swift", line: 1, column: 1, moduleName: "M"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        #expect(!diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("The strict cycle base case does not silence a direct self-call")
    func strictBaseCaseDoesNotSilenceSelfCall() {
        // The two tests are separate for a reason: `markHasBaseCase` answers the cycle
        // question. Letting it answer the self-call question too would reintroduce the
        // conflation that silently moved mutual-cycle 89 -> 72.
        let graph = USRCallGraph()
        let usr = "s:1M4LoopV6spinnyySiF"
        graph.addEdge(from: usr, to: usr)
        graph.markAnalysed(usr)
        graph.markHasBaseCase(usr)
        graph.setModuleName(usr, module: "M")
        graph.setSymbolInfo(usr, info: SymbolInfo(displayName: "spin(_:)", filePath: "L.swift", line: 1, column: 1, moduleName: "M"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        #expect(diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }


    @Test("Self base-case sites include computed properties, which are not callables")
    func selfBaseCaseSitesIncludeProperties() {
        // The index graph admits a property's getter, so a property that plainly returns
        // — GRDB's `containsNonNullValue` ends in `return false` — must be able to say so.
        // The *strict* set stays callable-only, because cycle detection filters the same way.
        let property = DeclarationInfo(
            signature: Signature(typeContext: "Row", displayName: "containsNonNullValue"),
            location: SourceLocation(file: "/Users/example/Row.swift", line: 1, column: 1),
            hasBaseCase: false,
            hasSelfBaseCase: true,
            wasAnalysed: true,
            outgoingCalls: [],
            isCallable: false
        )
        let site = DeclarationSite(path: "/Users/example/Row.swift", name: "containsNonNullValue")
        #expect(RecursionIndexPass.selfBaseCaseSites(from: [property]).contains(site))
        #expect(!RecursionIndexPass.baseCaseSites(from: [property]).contains(site))
    }


    @Test("Accessor symbol names normalise to the property name")
    func accessorNamesNormalise() {
        // IndexStoreDB names a computed property's accessors `getter:name` / `setter:name`,
        // while the AST pass records the property as `name`. Without stripping the prefix
        // the two never meet, and every property with a base case reads as unbounded.
        #expect(RecursionIndexPass.normalizedSymbolName("getter:containsNonNullValue") == "containsNonNullValue")
        #expect(RecursionIndexPass.normalizedSymbolName("setter:db") == "db")
        #expect(RecursionIndexPass.normalizedSymbolName("encode(_:)") == "encode(_:)")
    }


    // MARK: - Only assert on code the AST pass actually read

    @Test("A self-edge on a symbol the AST pass never analysed is not reported")
    func unanalysedSymbolIsNotReported() {
        // `@ObservableState struct State { @Presents var destination: Outer.State? }`.
        // The accessor the index sees is generated by the macro; the AST pass sees a *stored*
        // property, skips it for want of an accessor block, and so has no body to judge. The
        // index is right that the symbol references itself — through storage the macro wrote —
        // and we have no basis to call it unbounded.
        let graph = USRCallGraph()
        let usr = "s:3App5StateV11destinationAA5OuterVSgvg"
        graph.addEdge(from: usr, to: usr)
        graph.setModuleName(usr, module: "App")
        graph.setSymbolInfo(usr, info: SymbolInfo(
            displayName: "getter:destination", filePath: "F.swift", line: 19, column: 5, moduleName: "App"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        #expect(!diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("A self-edge on a symbol the AST pass did analyse is still reported")
    func analysedSymbolStillReported() {
        // The regression guard: a genuine self-recursive computed property has a getter the
        // AST pass read, so the guard must not silence it.
        let graph = USRCallGraph()
        let usr = "s:3App3BoxV5valueSivg"
        graph.addEdge(from: usr, to: usr)
        graph.markAnalysed(usr)
        graph.setModuleName(usr, module: "App")
        graph.setSymbolInfo(usr, info: SymbolInfo(
            displayName: "getter:value", filePath: "B.swift", line: 3, column: 5, moduleName: "App"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        #expect(diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("Analysed sites come only from declarations with a body")
    func analysedSitesRequireABody() {
        func declaration(_ name: String, analysed: Bool) -> DeclarationInfo {
            DeclarationInfo(
                signature: Signature(typeContext: "T", displayName: name),
                location: SourceLocation(file: "/Users/example/A.swift", line: 1, column: 1),
                hasBaseCase: false, hasSelfBaseCase: false, wasAnalysed: analysed,
                outgoingCalls: [], isCallable: true
            )
        }
        let sites = RecursionIndexPass.analysedSites(from: [
            declaration("withBody()", analysed: true),
            declaration("requirementOnly()", analysed: false),
        ])
        let path = "/Users/example/A.swift"
        #expect(sites.contains(DeclarationSite(path: path, name: "withBody()")))
        #expect(!sites.contains(DeclarationSite(path: path, name: "requirementOnly()")))
    }

}
