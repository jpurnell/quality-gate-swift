import Foundation
import Testing

// What `xctest-import --fix` writes, as code this target compiles and runs.
//
// `XCTestMigrationValidOutputTests` feeds each XCTest fixture to the fixer and requires the
// result to be, character for character, the suite between the matching markers below. So the
// fixer's output for every one of these cases is known to compile, because it is compiled
// here, and known to pass, because it runs with the rest of the suite. A change to the fixer
// that emits something else fails the comparison; a change that emits something that does not
// build cannot be recorded here at all.
//
// The markers are read by `CompiledConversion.suite(named:)`. Keep one blank line out of the
// regions: the text between the marker lines is compared exactly.

// MARK: - What the fixtures exercise

/// A cursor whose `next()` mutates, like the `ReviewQueue` that broke the SummerJams build.
struct FixtureQueue {
    private let items: [Int]
    private(set) var position = 0

    init(_ items: [Int]) {
        self.items = items
    }

    mutating func next() -> Bool {
        guard position + 1 < items.count else { return false }
        position += 1
        return true
    }
}

enum FixtureFailure: Error, Equatable {
    case bad
    case worse

    static func raise(_ failure: FixtureFailure) throws {
        throw failure
    }

    static func raiseLater(_ failure: FixtureFailure) async throws -> Int {
        throw failure
    }
}

struct FixtureRequest {
    let path: String
}

struct FixtureCell {
    let formula: String?
}

struct FixtureSheet {
    let references = [1, 2]

    func cell(at reference: Int) -> FixtureCell? {
        reference == 1 ? FixtureCell(formula: "=A1") : nil
    }
}

enum FixtureEnvironment {
    static let hasCorpus = true
    static let isCI = false
    static let corpusName = "corpus"
}

// MARK: - Converted suites

// fixture: mutatingCall
@Suite struct MutatingCallFixture {
    @Test func navigation() {
        var q = FixtureQueue([1, 2])
        let next = q.next()
        #expect(next)
        let next2 = q.next()
        #expect(!next2)
        #expect(q.position == 1)
    }
}
// end fixture

// fixture: notNil
@Suite struct NotNilFixture {
    @Test func lookup() throws {
        let table = ["a": 1]
        _ = try #require(table["a"], "present")
        #expect(table["a"] == 1)
    }

    @Test func asyncLookup() async throws {
        let table = ["a": 1]
        for key in ["a"] {
            _ = try #require(table[key])
        }
    }
}
// end fixture

// fixture: thrownErrorHandler
@Suite struct ThrownErrorHandlerFixture {
    @Test func handlerAsArgument() {
        if let error = #expect(throws: (any Error).self, "raises", performing: { try FixtureFailure.raise(.bad) }) {
            #expect(error as? FixtureFailure == .bad)
        }
    }

    @Test func patternGuard() {
        if let error = #expect(throws: (any Error).self, performing: { try FixtureFailure.raise(.bad) }) {
            guard case FixtureFailure.bad = error else {
                Issue.record("expected .bad, got \(error)"); return
            }
        }
    }
}
// end fixture

// fixture: doCatch
@Suite struct DoCatchFixture {
    @Test func typedCatch() async {
        await #expect(throws: FixtureFailure.self, "expected error to propagate") {
            _ = try await FixtureFailure.raiseLater(.bad)
        }
    }

    @Test func anyCatch() {
        #expect(throws: (any Error).self, "expected a failure") {
            try FixtureFailure.raise(.worse)
        }
    }
}
// end fixture

// fixture: coalesced
@Suite struct CoalescedFixture {
    @Test func fallback() throws {
        let request: FixtureRequest? = FixtureRequest(path: "/search_query=a")
        let path = try #require(request?.path)
        #expect(path.contains("search_query="))
        let isEmpty = try #require(request?.path.isEmpty as Bool?)
        #expect(!isEmpty, "has a path")
    }
}
// end fixture

// fixture: nestedUnwrap
@Suite struct NestedUnwrapFixture {
    @Test func lookup() throws {
        let keys: [String: Int] = ["a": 1]
        let rows: [Int: String] = [1: "first"]
        let keysElement = try #require(keys["a"])
        let row = try #require(rows[keysElement])
        #expect(row == "first")
        let rowsElement = try #require(rows[1])
        #expect(rowsElement.count == 5)
        let rowsElement2 = try #require(rows[1])
        #expect(row == rowsElement2)
    }
}
// end fixture

// fixture: closureProperty
@Suite struct ClosurePropertyFixture {
    @Test func firstFormula() throws {
        let sheet = FixtureSheet()
        let compactMapResult = sheet.references.compactMap { sheet.cell(at: $0)?.formula }
        let ast = try #require(compactMapResult.first)
        #expect(ast == "=A1")
        let mapResult = sheet.references.map { sheet.cell(at: $0)?.formula }
        #expect(!mapResult.isEmpty)
    }
}
// end fixture

// fixture: skipTrait
@Suite struct SkipTraitFixture {
    @Test(.enabled(if: FixtureEnvironment.hasCorpus, "the corpus is private")) func onlyWithCorpus() throws {
        #expect(FixtureEnvironment.corpusName == "corpus")
    }

    @Test(.enabled(if: !FixtureEnvironment.isCI, "not on CI")) func notOnCI() throws {
        #expect(FixtureEnvironment.corpusName == "corpus")
    }

    @Test(.enabled(if: !FixtureEnvironment.isCI)) func neverOnCI() throws {
        #expect(FixtureEnvironment.corpusName == "corpus")
    }
}
// end fixture

// fixture: multilineMessage
@Suite struct MultilineMessageFixture {
    @Test func longMessage() {
        let formats = ["B2": "General"]
        #expect(formats["B2"] == "General", Comment(rawValue: "carried rather than dropped: 'General' is what the file says, and "
                + "deciding it means nothing is the next stage's job"))
    }
}
// end fixture
