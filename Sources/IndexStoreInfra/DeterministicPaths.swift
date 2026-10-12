import Foundation

extension URL {

    /// Appends `component` without consulting the filesystem.
    ///
    /// `appendingPathComponent(_:)` is not a pure function on Linux: corelibs-foundation
    /// stats the resulting path and appends a trailing slash when it names an existing
    /// directory, where Darwin Foundation never stats at all. Two consequences, both of
    /// which this package had:
    ///
    /// - The same call returned `…/DataStore` on macOS and `…/DataStore/` on Linux, so every
    ///   comparison of such a URL differed by one character across platforms. Eight tests
    ///   failed on exactly that, with messages that looked like a locator returning the wrong
    ///   directory.
    /// - The shape depended on *when* the call ran. Before `createDirectory` it produced no
    ///   slash, after it produced one — so a URL built during a scan and a URL built from the
    ///   same components moments earlier were unequal, on one platform, depending on
    ///   filesystem state. That is the sort of order-dependence this package forbids in
    ///   tests and should not tolerate in its own path handling.
    ///
    /// `isDirectory: false` is passed for the trailing slash alone, not as a claim about what
    /// the path names: several of these components are directories. It is the value that
    /// leaves the URL identical to the one macOS has always produced, so making Linux agree
    /// cannot change behaviour on the platform every release is cut against.
    func appendingPathComponentUnstatted(_ component: String) -> URL {
        appendingPathComponent(component, isDirectory: false)
    }
}
