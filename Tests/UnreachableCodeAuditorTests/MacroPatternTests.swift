import Foundation
import Testing
@testable import UnreachableCodeAuditor

@Suite("Macro pattern recognition")
struct MacroPatternTests {

    @Test("Observation registrar")
    func observationRegistrar() {
        #expect(IndexStorePass.looksMacroGenerated("_$observationRegistrar"))
    }

    @Test("Underscored stored-property storage")
    func storedPropertyStorage() {
        #expect(IndexStorePass.looksMacroGenerated("_id"))
        #expect(IndexStorePass.looksMacroGenerated("_name"))
        #expect(IndexStorePass.looksMacroGenerated("_correlationR"))
    }

    @Test("Memberwise-init label form")
    func memberwiseInit() {
        #expect(IndexStorePass.looksMacroGenerated("init:name"))
        #expect(IndexStorePass.looksMacroGenerated("init:correlationR"))
        #expect(IndexStorePass.looksMacroGenerated("init:absoluteRank"))
    }

    @Test("Observable witness methods")
    func observableMethods() {
        #expect(IndexStorePass.looksMacroGenerated("withMutation(keyPath:_:)"))
        #expect(IndexStorePass.looksMacroGenerated("access(keyPath:)"))
        #expect(IndexStorePass.looksMacroGenerated("shouldNotifyObservers(_:_:)"))
    }

    @Test("Does not match normal names")
    func normalNamesNotMacro() {
        #expect(!IndexStorePass.looksMacroGenerated("compute"))
        #expect(!IndexStorePass.looksMacroGenerated("doStuff(arg:)"))
        #expect(!IndexStorePass.looksMacroGenerated("MyType"))
        #expect(!IndexStorePass.looksMacroGenerated("init(value:)"))
        #expect(!IndexStorePass.looksMacroGenerated("hash(into:)"))
    }
}
