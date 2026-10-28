import Foundation
import Testing
@testable import BuildChecker
@testable import QualityGateCore

// SwiftKeychain's adapters are behind traits that are off by default. `swift build` without
// `--traits` never compiled them, so a clean `build` said nothing about the code that ships
// to every consumer who turns them on.

@Suite("build: the configured package traits reach swift build")
struct BuildTraitsTests {

    @Test("Configured traits are passed to swift build as one --traits argument")
    func traitsArePassed() {
        var configuration = Configuration()
        configuration.traits = ["OAuth", "CLIAuth"]
        let arguments = BuildChecker().buildArguments(for: configuration)
        #expect(arguments.firstIndex(of: "--traits").map { arguments[$0 + 1] } == "OAuth,CLIAuth")
    }

    @Test("No configured traits pass no trait argument, exactly as before")
    func noTraitsPassNothing() {
        let arguments = BuildChecker().buildArguments(for: Configuration())
        #expect(!arguments.contains("--traits"))
        #expect(arguments == ["--build-tests"])
    }
}
