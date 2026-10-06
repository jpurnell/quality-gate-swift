import Foundation
import Testing
@testable import UnreachableCodeAuditor

// A member of a `public extension` is public without saying so. The liveness facts read a
// declaration's own modifiers and nothing else, so every such member of a library was a
// candidate for "unreachable from any entry point" — the modifiers, colours and fonts a
// library exists to export, in a package whose own callers are all outside it.

private let file = "/tmp/quality-gate-liveness/PublicExtension.swift"

/// The liveness fact recorded for the declaration named on `line` of `source`.
private func fact(_ source: String, line: Int) -> DeclFact? {
    var index = LivenessIndex()
    index.ingest(file: file, source: source)
    return index.fact(file: file, line: line)
}

@Suite("Liveness: members of a public extension")
struct PublicExtensionLivenessTests {

    @Test("A method, property, initializer and subscript in a public extension are public")
    func membersOfAPublicExtensionArePublic() {
        let source = """
        struct Box {}
        public extension Box {
            func padded() -> Box { self }
            var isEmpty: Bool { true }
            static func make() -> Box { Box() }
            init(label: String) { self.init() }
            subscript(index: Int) -> Int { index }
        }
        """
        #expect(fact(source, line: 3)?.isPublic == true)
        #expect(fact(source, line: 4)?.isPublic == true)
        #expect(fact(source, line: 5)?.isPublic == true)
        #expect(fact(source, line: 6)?.isPublic == true)
        #expect(fact(source, line: 7)?.isPublic == true)
    }

    @Test("A member that narrows its own access inside a public extension is not public")
    func narrowedMembersAreNotPublic() {
        let source = """
        struct Box {}
        public extension Box {
            private func hidden() {}
            fileprivate var secret: Int { 0 }
            internal func inside() {}
            package func shared() {}
        }
        """
        #expect(fact(source, line: 3)?.isPublic == false)
        #expect(fact(source, line: 4)?.isPublic == false)
        #expect(fact(source, line: 5)?.isPublic == false)
        #expect(fact(source, line: 6)?.isPublic == false)
    }

    @Test("A member of an extension with no access modifier is not public")
    func plainExtensionMembersAreNotPublic() {
        let source = """
        struct Box {}
        extension Box {
            func padded() -> Box { self }
            public func exported() -> Box { self }
        }
        """
        #expect(fact(source, line: 3)?.isPublic == false)
        #expect(fact(source, line: 4)?.isPublic == true)
    }

    @Test("An enum nested in a public extension is public, and so are its cases")
    func nestedEnumAndItsCasesArePublic() {
        let source = """
        struct Font {}
        public extension Font {
            enum Weight {
                case ultraLight
                case bold, heavy
            }
        }
        """
        #expect(fact(source, line: 3)?.isPublic == true)
        #expect(fact(source, line: 4)?.isPublic == true)
        #expect(fact(source, line: 5)?.isPublic == true)
    }

    @Test("A type nested in a public extension is public; its unmarked members are not")
    func nestedTypeMembersKeepTheirOwnDefault() {
        let source = """
        struct Font {}
        public extension Font {
            struct Metrics {
                var ascent: Int { 0 }
                public var descent: Int { 0 }
                func helper() {}
            }
        }
        """
        #expect(fact(source, line: 3)?.isPublic == true)
        #expect(fact(source, line: 4)?.isPublic == false)
        #expect(fact(source, line: 5)?.isPublic == true)
        #expect(fact(source, line: 6)?.isPublic == false)
    }

    @Test("A function declared inside a public extension's method is local, not public")
    func localFunctionsAreNotPublic() {
        let source = """
        struct Box {}
        public extension Box {
            func outer() {
                func inner() {}
                inner()
            }
        }
        """
        #expect(fact(source, line: 3)?.isPublic == true)
        #expect(fact(source, line: 4)?.isPublic == false)
    }

    @Test("A member behind #if in a public extension is public")
    func conditionallyCompiledMembersArePublic() {
        let source = """
        struct Box {}
        public extension Box {
            #if os(macOS)
            func desktopOnly() {}
            #else
            func elsewhere() {}
            #endif
        }
        """
        #expect(fact(source, line: 4)?.isPublic == true)
        #expect(fact(source, line: 6)?.isPublic == true)
    }

    @Test("A private enum nested in a public extension keeps its cases private")
    func narrowedNestedEnumCasesAreNotPublic() {
        let source = """
        struct Font {}
        public extension Font {
            private enum Slot {
                case first
            }
        }
        """
        #expect(fact(source, line: 3)?.isPublic == false)
        #expect(fact(source, line: 4)?.isPublic == false)
    }
}
