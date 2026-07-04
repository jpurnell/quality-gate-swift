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

    // MARK: - requiresNativeBuildSystem (the 6.4 boundary)

    @Test("6.4 requires native build system")
    func exactly64RequiresNative() {
        #expect(StoreLocator.requiresNativeBuildSystem(major: 6, minor: 4) == true)
    }

    @Test("6.3 does not require native build system")
    func just63DoesNot() {
        #expect(StoreLocator.requiresNativeBuildSystem(major: 6, minor: 3) == false)
    }

    @Test("Older majors do not require native")
    func olderMajor() {
        #expect(StoreLocator.requiresNativeBuildSystem(major: 5, minor: 10) == false)
        #expect(StoreLocator.requiresNativeBuildSystem(major: 6, minor: 0) == false)
    }

    @Test("Newer versions require native")
    func newerVersions() {
        #expect(StoreLocator.requiresNativeBuildSystem(major: 6, minor: 5) == true)
        #expect(StoreLocator.requiresNativeBuildSystem(major: 7, minor: 0) == true)
    }
}
