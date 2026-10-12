import Foundation

/// Locating the products a test needs to execute, on both platforms that run these tests.
///
/// Acceptance tests here do not exercise a checker in-process; they run the built
/// `quality-gate` and read what it wrote. Finding that binary is the one step of those
/// tests that is platform-dependent, and it was written the Darwin way.
public enum BuiltProducts {

    /// The directory the current test's products were built into.
    ///
    /// `Bundle(for:)` needs the Objective-C runtime to map a class back to the bundle that
    /// contains it. On Darwin that yields the `.xctest` bundle, whose parent is the products
    /// directory. Linux has no such runtime and no `.xctest` bundle: corelibs-foundation
    /// answers something unrelated, the binary is looked for beside it, and ten acceptance
    /// tests throw `binaryNotFound` having proven nothing about the code they were written
    /// to test.
    ///
    /// On Linux the test runner *is* the executable, so `Bundle.main.bundleURL` is already
    /// the products directory.
    public static var directory: URL {
        #if canImport(ObjectiveC)
        // `Bundle(for:)` on a class this library owns. It needs the Objective-C runtime to
        // map the class back to the bundle containing it, which is the `.xctest` the tests
        // were linked into; its parent is the products directory.
        //
        // Not `Bundle.allBundles`: that was the first attempt here and it broke all ten
        // acceptance tests on macOS, because the bundle is not in that list under the
        // swift-testing runner. The Darwin path already worked — the job was to add Linux,
        // not to replace both with something neither had been tested against.
        return Bundle(for: ProductsToken.self).bundleURL.deletingLastPathComponent()
        #else
        // No Objective-C runtime and no bundle: on Linux the test runner *is* the executable
        // and sits in the products directory.
        return Bundle.main.bundleURL
        #endif
    }

    /// Anchors `Bundle(for:)` to this library. A class, because that API takes `AnyClass`.
    private final class ProductsToken {}

    /// The built `quality-gate` executable, or `nil` when it is not beside the tests.
    ///
    /// Returns `nil` rather than throwing so each suite keeps its own error type and its own
    /// decision about whether a missing binary is a skip or a failure.
    public static var gateBinary: URL? {
        let candidate = directory.appendingPathComponent("quality-gate")
        // SAFETY: read-only existence check in the build directory.
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
