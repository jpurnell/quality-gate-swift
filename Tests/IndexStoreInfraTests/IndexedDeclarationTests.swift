import Foundation
import Testing
@testable import IndexStoreInfra

/// Whether a definition the index reports is still written where the index says it is.
///
/// The index records a symbol's name and the line of its definition as they were when the unit
/// was compiled. A checker that turns that record into a finding is quoting the index, and the
/// reader will open the file. The least a finding owes them is that the line it names still
/// mentions the symbol.
@Suite("Indexed declaration against current source")
struct IndexedDeclarationTests {

    @Test("a function's base name is its indexed name without the argument labels")
    func baseNameDropsArgumentLabels() {
        #expect(IndexedDeclaration.baseName(ofIndexedName: "neverCalled()") == "neverCalled")
        #expect(IndexedDeclaration.baseName(ofIndexedName: "validate(_:)") == "validate")
        #expect(IndexedDeclaration.baseName(ofIndexedName: "init(from:)") == "init")
        #expect(IndexedDeclaration.baseName(ofIndexedName: "subscript(_:)") == "subscript")
    }

    @Test("a property or enum case is indexed under its own name")
    func baseNameOfAPropertyIsItself() {
        #expect(IndexedDeclaration.baseName(ofIndexedName: "obsoleteQRCodeError") == "obsoleteQRCodeError")
    }

    @Test("an operator keeps its spelling")
    func baseNameOfAnOperator() {
        #expect(IndexedDeclaration.baseName(ofIndexedName: "+(_:_:)") == "+")
        // `()` is the call operator's own name, not an empty one followed by labels.
        #expect(IndexedDeclaration.baseName(ofIndexedName: "(_:)") == "(_:)")
    }

    /// The Ignite case exactly: the index said `obsoleteVersion` at line 11, and line 11 held
    /// the case that had moved up to take its place.
    @Test("a line holding a different declaration does not match")
    func differentDeclarationOnTheLine() {
        #expect(IndexedDeclaration.appears(
            indexedName: "obsoleteQRCodeError", inSourceLine: "    case lastQRCodeError") == false)
    }

    @Test("a line that still declares the symbol matches")
    func sameDeclarationOnTheLine() {
        #expect(IndexedDeclaration.appears(
            indexedName: "neverCalled()", inSourceLine: "    func neverCalled() -> Int { 42 }"))
        #expect(IndexedDeclaration.appears(
            indexedName: "lastQRCodeError", inSourceLine: "    case lastQRCodeError"))
        #expect(IndexedDeclaration.appears(
            indexedName: "init(from:)", inSourceLine: "    init(from decoder: any Decoder) throws {"))
    }

    @Test("one of several declarations on a line matches")
    func severalDeclarationsOnOneLine() {
        #expect(IndexedDeclaration.appears(indexedName: "beta", inSourceLine: "    case alpha, beta, gamma"))
    }

    /// A name that is only a *prefix* of what the line declares is a different symbol.
    @Test("a longer identifier that merely contains the name does not match")
    func prefixOfALongerIdentifier() {
        #expect(IndexedDeclaration.appears(
            indexedName: "last", inSourceLine: "    case lastQRCodeError") == false)
        #expect(IndexedDeclaration.appears(
            indexedName: "Error", inSourceLine: "    case lastQRCodeError") == false)
    }

    @Test("a line past the end of the file matches nothing")
    func lineBeyondTheFile() {
        #expect(IndexedDeclaration.appears(indexedName: "anything", inSourceLine: nil) == false)
    }

    @Test("a backticked identifier matches the name the index stores without them")
    func backtickedIdentifier() {
        #expect(IndexedDeclaration.appears(indexedName: "default", inSourceLine: "    case `default`"))
    }
}
