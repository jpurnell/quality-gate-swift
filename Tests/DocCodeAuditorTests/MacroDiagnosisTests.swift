import Testing
@testable import DocCodeAuditor

@Suite("Macro diagnosis")
struct MacroDiagnosisTests {

    /// The compiler's message, verbatim. It names the plugin module in every case,
    /// which is why it reads as "the plugin is missing" even when the plugin is
    /// present and merely does not register the type.
    static let compilerMessage = """
        external macro implementation type 'BusinessMathMacrosImpl.ValidatedMacro' could not be \
        found for macro 'Validated()'; plugin for module 'BusinessMathMacrosImpl' not found
        """

    @Test("Recognises the compiler's external-macro diagnostic")
    func recognisesTheDiagnostic() {
        let parsed = MacroDiagnosis.parse(Self.compilerMessage)
        #expect(parsed?.pluginModule == "BusinessMathMacrosImpl")
        #expect(parsed?.implementationType == "ValidatedMacro")
        #expect(parsed?.macroName == "Validated")
    }

    @Test("Ignores unrelated compile errors")
    func ignoresOtherErrors() {
        #expect(MacroDiagnosis.parse("cannot find 'balanceSheet' in scope") == nil)
        #expect(MacroDiagnosis.parse("") == nil)
    }

    /// Cause one: the plugin was never built. `.build/debug/<Plugin>` is absent, so
    /// there is nothing to load and the author's macro code is irrelevant.
    @Test("Plugin absent from the build is diagnosed as not built")
    func pluginNotBuilt() {
        let explanation = MacroDiagnosis.explain(
            MacroDiagnosis(pluginModule: "XImpl", implementationType: "FooMacro", macroName: "Foo"),
            pluginWasBuilt: false,
            registeredTypes: [])
        #expect(explanation.contains("was not built"))
        #expect(!explanation.contains("providingMacros"))
    }

    /// Cause two, and the one the compiler's wording actively misdirects. The plugin
    /// is built and loaded; the type simply is not in `providingMacros`, so the
    /// compiler cannot find it and blames the plugin.
    @Test("Plugin built but type unregistered is diagnosed as a registration gap")
    func typeNotRegistered() {
        let explanation = MacroDiagnosis.explain(
            MacroDiagnosis(pluginModule: "XImpl", implementationType: "FooMacro", macroName: "Foo"),
            pluginWasBuilt: true,
            registeredTypes: ["BarMacro", "BazMacro"])
        #expect(explanation.contains("providingMacros"))
        #expect(explanation.contains("FooMacro"))
        #expect(!explanation.contains("was not built"))
    }

    /// Both causes excluded: the plugin is built and the type *is* registered, so
    /// the checker must not invent a third explanation it cannot support.
    @Test("Registered and built yields no confident cause")
    func noConfidentCause() {
        let explanation = MacroDiagnosis.explain(
            MacroDiagnosis(pluginModule: "XImpl", implementationType: "FooMacro", macroName: "Foo"),
            pluginWasBuilt: true,
            registeredTypes: ["FooMacro"])
        #expect(explanation.contains("could not determine"))
    }

    // MARK: - Reading the plugin's registration

    @Test("Reads providingMacros past the [Macro.Type] annotation")
    func readsRegistrations() {
        let plugin = """
            @main
            struct XPlugin: CompilerPlugin {
                let providingMacros: [Macro.Type] = [
                    // Validation
                    ValidatedMacro.self,
                    PositiveMacro.self,
                ]
            }
            """
        #expect(MacroDiagnosis.registeredTypes(inPluginSource: plugin)
            == ["PositiveMacro", "ValidatedMacro"])
    }

    /// The naive read takes the first `]`, which closes the *type annotation*
    /// `[Macro.Type]` and yields an empty list — reporting every macro in the package
    /// as unregistered. That false positive was produced while measuring this very
    /// class, so the parser bracket-matches.
    @Test("The type annotation's bracket does not truncate the list")
    func annotationDoesNotTruncate() {
        let plugin = "let providingMacros: [Macro.Type] = [ OnlyMacro.self ]"
        #expect(MacroDiagnosis.registeredTypes(inPluginSource: plugin) == ["OnlyMacro"])
    }

    @Test("A source with no plugin declaration registers nothing")
    func noPlugin() {
        #expect(MacroDiagnosis.registeredTypes(inPluginSource: "struct Nothing {}").isEmpty)
    }
}
