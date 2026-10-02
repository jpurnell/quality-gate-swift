import Foundation
import Testing
@testable import DocLinter

/// Narrowing a DocC diagnostic's candidates to the module its context names.
///
/// The filter was `$0.hasPrefix(moduleDir)` with no separator, so a context in module `Foo`
/// also took every file of `FooBar`.
@Suite("DocLinter context narrowing")
struct ContextNarrowingTests {

    @Test("A module's files do not include a module whose name extends it")
    func siblingModuleIsExcluded() {
        let files = ["/p/Sources/Foo/a.swift", "/p/Sources/FooBar/b.swift"]
        let narrowed = DocLinter.narrowFilesForContext("Foo", sourcesPath: "/p/Sources", allFiles: files)
        #expect(narrowed == ["/p/Sources/Foo/a.swift"])
    }
}
