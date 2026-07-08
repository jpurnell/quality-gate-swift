import Foundation
import Testing
@testable import LegibilityAnalyzer

@Suite("PublicSurfaceScanner")
struct PublicSurfaceScannerTests {

    private let scanner = PublicSurfaceScanner()

    @Test("collects public declarations and ignores non-public ones")
    func collectsPublicOnly() {
        let source = """
        public struct Widget {
            public func doThing() {}
            func hidden() {}
            private var secret = 0
        }
        """
        let symbols = scanner.scan(source: source)
        let names = symbols.map(\.name)
        #expect(names.contains("Widget"))
        #expect(names.contains("doThing"))
        #expect(!names.contains("hidden"))
        #expect(!names.contains("secret"))
        #expect(symbols.count == 2)
    }

    @Test("recognizes every public declaration kind")
    func recognizesKinds() {
        let source = """
        public struct S {}
        public class C {}
        public enum E {}
        public protocol P {}
        public actor A {}
        public typealias T = Int
        public func f() {}
        public let v = 0
        public init() {}
        """
        let byName = Dictionary(uniqueKeysWithValues: scanner.scan(source: source).map { ($0.name, $0.kind) })
        #expect(byName["S"] == .structDecl)
        #expect(byName["C"] == .classDecl)
        #expect(byName["E"] == .enumDecl)
        #expect(byName["P"] == .protocolDecl)
        #expect(byName["A"] == .actorDecl)
        #expect(byName["T"] == .typealiasDecl)
        #expect(byName["f"] == .function)
        #expect(byName["v"] == .property)
        #expect(byName["init"] == .initializer)
    }

    @Test("doc-comment presence is detected per declaration")
    func docCommentDetection() {
        let source = """
        /// Does a documented thing.
        public func documented() {}
        public func undocumented() {}
        """
        let byName = Dictionary(uniqueKeysWithValues: scanner.scan(source: source).map { ($0.name, $0.hasDocComment) })
        #expect(byName["documented"] == true)
        #expect(byName["undocumented"] == false)
    }

    @Test("open declarations are flagged as open")
    func openDetection() {
        let source = """
        open class Base {}
        public class Sealed {}
        """
        let byName = Dictionary(uniqueKeysWithValues: scanner.scan(source: source).map { ($0.name, $0.isOpen) })
        #expect(byName["Base"] == true)
        #expect(byName["Sealed"] == false)
    }

    @Test("reserved marker acknowledges an over-public symbol")
    func reservedMarkerDetection() {
        let source = """
        // legibility:reserved kept for downstream packages
        public func reservedAPI() {}
        public func plainAPI() {}
        """
        let byName = Dictionary(uniqueKeysWithValues: scanner.scan(source: source).map { ($0.name, $0.hasReservedMarker) })
        #expect(byName["reservedAPI"] == true)
        #expect(byName["plainAPI"] == false)
    }

    @Test("nested public members are part of the surface")
    func nestedPublicMembers() {
        let source = """
        public struct Outer {
            public struct Inner {
                public func deep() {}
            }
        }
        """
        let names = Set(scanner.scan(source: source).map(\.name))
        #expect(names == ["Outer", "Inner", "deep"])
    }

    @Test("isType distinguishes type declarations from members")
    func isTypeClassification() {
        #expect(PublicSymbolKind.structDecl.isType)
        #expect(PublicSymbolKind.classDecl.isType)
        #expect(PublicSymbolKind.enumDecl.isType)
        #expect(PublicSymbolKind.protocolDecl.isType)
        #expect(PublicSymbolKind.actorDecl.isType)
        #expect(!PublicSymbolKind.property.isType)
        #expect(!PublicSymbolKind.function.isType)
        #expect(!PublicSymbolKind.initializer.isType)
        #expect(!PublicSymbolKind.typealiasDecl.isType)
    }

    @Test("line numbers are 1-based and accurate")
    func lineNumbers() {
        let source = """
        public struct First {}
        public struct Second {}
        """
        let byName = Dictionary(uniqueKeysWithValues: scanner.scan(source: source).map { ($0.name, $0.line) })
        #expect(byName["First"] == 1)
        #expect(byName["Second"] == 2)
    }
}
