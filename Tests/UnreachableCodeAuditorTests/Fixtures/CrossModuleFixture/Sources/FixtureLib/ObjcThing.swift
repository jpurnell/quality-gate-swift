import Foundation

// `@objc` requires the Objective-C runtime, which only Apple platforms have: off Darwin the
// compiler answers `error: Objective-C interoperability is disabled` and the whole fixture
// package fails to build. Since the checker under test is what builds this fixture, that
// surfaced as the index store being unavailable rather than as a fixture that cannot compile,
// and it cost every index-backed test on the 6.4 leg.
//
// This was the *second* Darwin-only file here. `SwiftUIPatterns.swift` was the first, and
// fixing it only revealed this one, because the compiler stops at the first file that fails.
// The lesson is in the ordering: the error named one file, the fixture had two, and checking
// the rest of the directory would have found both at once.
//
// The rule this fixture exists to pin — an `@objc` method may be called dynamically through
// KVC or a selector and must not be flagged as dead — is a statement about a runtime that is
// not present here. `CrossModuleTests` asserts `ping` is never flagged; off Darwin it does not
// exist, so it is not flagged, and the assertion holds for a different reason than it does on
// macOS. That is the honest shape for a rule about Objective-C: tested where Objective-C is.
#if canImport(ObjectiveC)
// `@objc` methods may be called dynamically (KVC, selectors, IB) — must
// NOT be flagged even with no static references.
public class ObjcThing: NSObject {
    @objc public func ping() {}
}
#endif
