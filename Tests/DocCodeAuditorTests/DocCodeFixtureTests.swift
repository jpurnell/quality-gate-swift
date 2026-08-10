import Foundation
import Testing
@testable import DocCodeAuditor

/// End-to-end fixtures: real markdown, real `swiftc -typecheck`, real verdict.
///
/// These compile against the standard library only, so they need no built module and no
/// network — the auditor's own behaviour is what is under test, not any package's
/// documentation.
///
/// The last test in this file is the one that matters most. An earlier harness in this
/// project reported the *same* error count for known-good and known-bad code, because its
/// flags were being word-split and silently dropped, and it was believed for an hour. A
/// checker that cannot fail is worse than no checker, because it certifies.
@Suite("Doc Code Fixtures", .serialized)
struct DocCodeFixtureTests {

    // MARK: - Harness

    /// Writes `markdown` to a temporary `.md` and audits it exactly as the checker would.
    private func audit(_ markdown: String, named name: String = "Fixture.md") throws -> ArticleVerdict {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-code-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let article = directory.appendingPathComponent(name)
        try markdown.write(to: article, atomically: true, encoding: .utf8)

        var options = DocCodeAuditOptions()
        options.imports = ["Foundation"]
        options.languageFlags = ["-swift-version", "6"]
        return try ArticleAuditor.audit(article: article, options: options)
    }

    // MARK: - Must fail

    @Test("An article calling a function with a wrong argument label fails")
    func wrongArgumentLabelFails() throws {
        let verdict = try audit("""
        # Greeting

        ```swift
        func greet(name: String) -> String { "hello, \\(name)" }
        ```

        And to use it:

        ```swift
        print(greet(person: "Ada"))
        ```
        """)
        #expect(!verdict.passed)
        #expect(!verdict.compileErrors.isEmpty)
        // The diagnostic must point at the article, at the line that actually calls it —
        // line 10, inside the second fence, not anywhere in the temporary file.
        #expect(verdict.compileErrors.contains { $0.articleLine == 10 })
    }

    @Test("An article naming a symbol nothing defines fails")
    func undefinedSymbolFails() throws {
        let verdict = try audit("""
        # Undefined

        ```swift
        let total = quarterlyRevenue.reduce(0, +)
        ```
        """)
        #expect(!verdict.passed)
        #expect(verdict.compileErrors.contains { $0.message.contains("quarterlyRevenue") })
        #expect(verdict.compileErrors.contains { $0.articleLine == 4 })
    }

    @Test("Two blocks colliding on a name fail, and the collision is named")
    func collisionFails() throws {
        // Under the one-program convention this is a defect in the article, and the repair
        // is a rename — `salesData`, `returnsData` — not an annotation.
        let verdict = try audit("""
        # Collision

        ```swift
        let data = [1, 2, 3]
        print(data.count)
        ```

        A second, unrelated example:

        ```swift
        let data = ["a", "b"]
        print(data.first ?? "")
        ```
        """)
        #expect(!verdict.passed)
        let collision = try #require(verdict.collisions.first { $0.name == "data" })
        #expect(collision.kind == "let")
        #expect(collision.articleLines == [4, 11])
    }

    @Test("A fence indented inside a list item fails when its code is wrong")
    func indentedFenceWithErrorFails() throws {
        // The coverage regression, expressed as a verdict. When fences were matched at
        // column 0 this article passed — with the defect still in it.
        let verdict = try audit("""
        # Troubleshooting

        If the optimizer stalls:

        1. Lower the tolerance:

           ```swift
           let tolerance = undefinedDefaultTolerance
           ```

        2. Try again.
        """)
        #expect(verdict.fencesFound == 1)
        #expect(verdict.fencesChecked == 1)
        #expect(!verdict.passed)
        #expect(verdict.compileErrors.contains { $0.articleLine == 8 })
    }

    // MARK: - Must pass

    @Test("An article whose later blocks build on earlier ones passes")
    func continuationPasses() throws {
        // The whole convention: an article is one program, so a later block referring to an
        // earlier binding is correct and must keep working.
        let verdict = try audit("""
        # Building Up

        ```swift
        let revenue = [100.0, 120.0, 115.0]
        ```

        Now summarise it:

        ```swift
        let total = revenue.reduce(0, +)
        let mean = total / Double(revenue.count)
        ```

        And report:

        ```swift
        print("mean revenue: \\(mean)")
        ```
        """)
        #expect(verdict.passed)
        #expect(verdict.fencesChecked == 3)
        #expect(verdict.compileErrors.isEmpty)
        #expect(verdict.collisions.isEmpty)
    }

    @Test("An article with a legitimately exempted block passes, and the exemption is counted")
    func exemptedBlockPasses() throws {
        let verdict = try audit("""
        # Signatures

        The initialiser's shape:

        <!-- docs:illustrative -->
        ```swift
        public init(low: Double, high: Double, base: Double) throws
        ```

        In use:

        ```swift
        let low = 1.0
        print(low)
        ```
        """)
        #expect(verdict.passed)
        #expect(verdict.fencesFound == 2)
        #expect(verdict.fencesChecked == 1)
        #expect(verdict.fencesExempt == 1)
    }

    @Test("An article whose only Swift is a @Test block passes")
    func testingBlockPasses() throws {
        // Without `-F <platform frameworks>` and the testing macro `-plugin-path`, this
        // fails with "no such module 'Testing'" and then with a missing macro plugin.
        // Neither is a documentation defect, and exempting the block to make the auditor
        // pass would be a false clean: the gate would have manufactured its own exemption.
        let verdict = try audit("""
        # Verifying

        ```swift
        import Testing

        @Test func meanIsCorrect() {
            #expect([1.0, 2.0, 3.0].reduce(0, +) / 3 == 2.0)
        }
        ```
        """)
        #expect(verdict.passed)
        #expect(verdict.fencesChecked == 1)
        #expect(verdict.compileErrors.isEmpty)
    }

    @Test("A non-Swift fence is neither checked nor counted against coverage")
    func nonSwiftFenceIgnored() throws {
        let verdict = try audit("""
        # Install

        ```bash
        swift build --configuration release
        ```

        ```json
        { "version": "1.0" }
        ```
        """)
        #expect(verdict.passed)
        #expect(verdict.fencesFound == 0)
    }

    // MARK: - Barriers

    @Test("An unresolvable import is reported as a barrier, not as one error among many")
    func failedImportIsABarrier() throws {
        // A `no such module` aborts compilation before typechecking, so every error behind
        // it is invisible. 3.15-DataIngestionGuide ranked as a 1-error article; its real
        // state was ~27. Reporting the count without the barrier misleads whoever plans
        // the work.
        let verdict = try audit("""
        # Ingestion

        ```swift
        import SomeModuleThatDoesNotExistAnywhere
        let x = 1
        ```
        """)
        #expect(!verdict.passed)
        let barrier = try #require(verdict.barrier)
        #expect(barrier.contains("SomeModuleThatDoesNotExistAnywhere"))
    }

    // MARK: - Negative control

    @Test("Known-good and known-bad input produce different verdicts")
    func negativeControl() throws {
        let good = """
        # Good

        ```swift
        func area(width: Double, height: Double) -> Double { width * height }
        ```

        ```swift
        print(area(width: 3, height: 4))
        ```
        """
        let bad = """
        # Bad

        ```swift
        func area(width: Double, height: Double) -> Double { width * height }
        ```

        ```swift
        print(area(w: 3, h: 4))
        ```
        """

        let goodVerdict = try audit(good, named: "Good.md")
        let badVerdict = try audit(bad, named: "Bad.md")

        // Same shape, same block count — the *only* difference is whether the code is right.
        #expect(goodVerdict.fencesChecked == badVerdict.fencesChecked)
        #expect(goodVerdict.compileErrors.count == 0)
        #expect(badVerdict.compileErrors.count >= 1)
        #expect(badVerdict.compileErrors.count > goodVerdict.compileErrors.count)
        #expect(goodVerdict.passed)
        #expect(!badVerdict.passed)
    }
}
