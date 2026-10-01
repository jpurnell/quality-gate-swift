import Foundation
import Testing
@testable import IndexStoreInfra

@Suite("IndexStoreSession")
struct IndexStoreSessionTests {

    /// Renamed from "…on macOS". The library ships on Linux too — as
    /// `libIndexStore.so`, at `/usr/lib` in the official Swift container — and the
    /// resolution only ever looked for Darwin's `.dylib`. It therefore answered `nil`
    /// there, and the `unreachable` checker reported **passed** with no findings rather
    /// than reporting that it had no index store to consult: seven cross-module tests
    /// failed on a vacuous pass, which is the failure mode this package treats as worse
    /// than a false positive.
    @Test("findLibIndexStore finds the platform's library")
    func findsLibIndexStore() throws {
        let path = try #require(IndexStoreSession.findLibIndexStore())
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
}

/// How the index-store library is located, independent of the platform running the test.
///
/// The resolution is a pure function over an existence predicate so both platforms' layouts
/// are exercised everywhere. Darwin-only tests are why the `.so` gap survived: nothing
/// compiled the Linux branch, so nothing contradicted it.
@Suite("libIndexStore resolution")
struct LibIndexStoreResolutionTests {

    @Test("Each platform looks for its own library name")
    func platformLibraryName() {
        #if canImport(Darwin)
        #expect(IndexStoreSession.libraryFileName == "libIndexStore.dylib")
        #else
        #expect(IndexStoreSession.libraryFileName == "libIndexStore.so")
        #endif
    }

    /// The Linux container's actual layout: `swift` at `/usr/bin/swift`, library at
    /// `/usr/lib/libIndexStore.so`.
    @Test("The library is derived from the toolchain holding `swift`")
    func derivedFromToolchain() {
        let resolved = IndexStoreSession.resolveLibIndexStore(
            toolchainBinary: "/usr/bin/swift",
            fallbacks: [],
            libraryFileName: "libIndexStore.so",
            exists: { $0 == "/usr/lib/libIndexStore.so" })

        #expect(resolved?.path == "/usr/lib/libIndexStore.so")
    }

    @Test("A fallback answers when the toolchain does not hold the library")
    func fallbackAnswers() {
        let resolved = IndexStoreSession.resolveLibIndexStore(
            toolchainBinary: "/opt/swift/usr/bin/swift",
            fallbacks: ["/usr/lib/libIndexStore.so"],
            libraryFileName: "libIndexStore.so",
            exists: { $0 == "/usr/lib/libIndexStore.so" })

        #expect(resolved?.path == "/usr/lib/libIndexStore.so")
    }

    /// The toolchain wins, because the library must match the toolchain that produced the
    /// store or cross-module lookups silently return nothing — the same mismatch the Darwin
    /// resolution was reordered to avoid.
    @Test("The toolchain's own library is preferred over any fallback")
    func toolchainBeatsFallback() {
        let resolved = IndexStoreSession.resolveLibIndexStore(
            toolchainBinary: "/opt/swift/usr/bin/swift",
            fallbacks: ["/usr/lib/libIndexStore.so"],
            libraryFileName: "libIndexStore.so",
            exists: { _ in true })

        #expect(resolved?.path == "/opt/swift/usr/lib/libIndexStore.so")
    }

    @Test("Nothing anywhere resolves to nil rather than a path that does not exist")
    func nothingResolvesToNil() {
        let resolved = IndexStoreSession.resolveLibIndexStore(
            toolchainBinary: "/usr/bin/swift",
            fallbacks: ["/usr/lib/libIndexStore.so"],
            libraryFileName: "libIndexStore.so",
            exists: { _ in false })

        #expect(resolved == nil)
    }

    @Test("With no toolchain on PATH the fallbacks are still consulted")
    func noToolchainStillUsesFallbacks() {
        let resolved = IndexStoreSession.resolveLibIndexStore(
            toolchainBinary: nil,
            fallbacks: ["/a/libIndexStore.dylib", "/b/libIndexStore.dylib"],
            libraryFileName: "libIndexStore.dylib",
            exists: { $0 == "/b/libIndexStore.dylib" })

        #expect(resolved?.path == "/b/libIndexStore.dylib")
    }
}
