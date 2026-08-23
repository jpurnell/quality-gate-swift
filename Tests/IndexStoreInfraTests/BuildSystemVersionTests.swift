import Foundation
import Testing
@testable import IndexStoreInfra

@Suite("StoreLocator: build-system version gating")
struct BuildSystemVersionTests {

    // MARK: - parseSwiftVersion

    @Test("Parses Apple Swift version string")
    func parsesAppleFormat() {
        let v = StoreLocator.parseSwiftVersion(
            fromVersionOutput: "Apple Swift version 6.4 (swiftlang-6.4.0.23.5 clang-2100.3.23.3)"
        )
        #expect(v?.major == 6)
        #expect(v?.minor == 4)
    }

    @Test("Parses open-source Swift version string with patch")
    func parsesOpenSourceFormat() {
        let v = StoreLocator.parseSwiftVersion(
            fromVersionOutput: "Swift version 6.0.1 (swift-6.0.1-RELEASE)\nTarget: x86_64-unknown-linux-gnu"
        )
        #expect(v?.major == 6)
        #expect(v?.minor == 0)
    }

    @Test("Parses dev snapshot version")
    func parsesDevSnapshot() {
        let v = StoreLocator.parseSwiftVersion(fromVersionOutput: "Swift version 6.2-dev (LLVM ..., Swift ...)")
        #expect(v?.major == 6)
        #expect(v?.minor == 2)
    }

    @Test("Returns nil for unrecognized output")
    func nilForGarbage() {
        #expect(StoreLocator.parseSwiftVersion(fromVersionOutput: "not a version string") == nil)
    }

    // MARK: - toolchainIndexesDuringOrdinaryBuild (the same 6.4 boundary, read the other way)
    //
    // 6.4+ SwiftPM defaults to swiftbuild, which index-while-builds to `.build/out` during an
    // ordinary build. Below 6.4 the ordinary build produces no store, so the dedicated
    // `-index-store-path` build is still required there.

    @Test("6.4 indexes during an ordinary build")
    func exactly64IndexesOrdinarily() {
        #expect(StoreLocator.toolchainIndexesDuringOrdinaryBuild(major: 6, minor: 4) == true)
    }

    @Test("6.3 does not index during an ordinary build")
    func just63DoesNot() {
        #expect(StoreLocator.toolchainIndexesDuringOrdinaryBuild(major: 6, minor: 3) == false)
    }

    @Test("Older toolchains need the dedicated index build")
    func olderMajor() {
        #expect(StoreLocator.toolchainIndexesDuringOrdinaryBuild(major: 5, minor: 10) == false)
        #expect(StoreLocator.toolchainIndexesDuringOrdinaryBuild(major: 6, minor: 0) == false)
    }

    @Test("Newer toolchains index during an ordinary build")
    func newerVersions() {
        #expect(StoreLocator.toolchainIndexesDuringOrdinaryBuild(major: 6, minor: 5) == true)
        #expect(StoreLocator.toolchainIndexesDuringOrdinaryBuild(major: 7, minor: 0) == true)
    }

    @Test("The deprecated build-system flag is gone from every invocation")
    func noBuildSystemFlag() {
        // `--build-system native` warns on every index build today and is scheduled for
        // removal. The dedicated build now runs only on toolchains where `native` is already
        // the default, so the flag is never needed.
        let arguments = StoreLocator.buildArguments(
            packageRoot: URL(fileURLWithPath: "/tmp/pkg"),
            buildPath: URL(fileURLWithPath: "/tmp/pkg/.build/index-build"),
            store: URL(fileURLWithPath: "/tmp/pkg/.build/index-build/index-store"),
            includeTests: true
        )
        #expect(!arguments.contains("--build-system"))
        #expect(!arguments.contains("native"))
        #expect(arguments.contains("-index-store-path"))
    }

}
