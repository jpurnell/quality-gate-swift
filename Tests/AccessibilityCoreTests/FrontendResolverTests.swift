import Testing
@testable import AccessibilityCore

@Suite("FrontendResolver")
struct FrontendResolverTests {

    @Test("SwiftUI import resolves to .swiftUI")
    func swiftUIImport() {
        #expect(FrontendResolver.resolve(importedModules: ["SwiftUI"]) == [.swiftUI])
    }

    @Test("SwiftCLIKit import resolves to .cli")
    func swiftCLIKitImport() {
        #expect(FrontendResolver.resolve(importedModules: ["SwiftCLIKit"]) == [.cli])
    }

    @Test("ArgumentParser import resolves to .cli")
    func argumentParserImport() {
        #expect(FrontendResolver.resolve(importedModules: ["ArgumentParser"]) == [.cli])
    }

    @Test("JavaScriptKit import resolves to .web")
    func javaScriptKitImport() {
        #expect(FrontendResolver.resolve(importedModules: ["JavaScriptKit"]) == [.web])
    }

    @Test("Both SwiftUI and SwiftCLIKit resolve to both frontends")
    func multipleFrontends() {
        #expect(
            FrontendResolver.resolve(importedModules: ["SwiftUI", "SwiftCLIKit"]) == [.swiftUI, .cli]
        )
    }

    @Test("Non-UI imports resolve to no frontends")
    func noFrontend() {
        #expect(FrontendResolver.resolve(importedModules: ["Foundation", "os"]).isEmpty)
    }

    @Test("Empty import set resolves to no frontends")
    func emptyImports() {
        #expect(FrontendResolver.resolve(importedModules: []).isEmpty)
    }
}
