import Foundation

// `@objc` methods may be called dynamically (KVC, selectors, IB) — must
// NOT be flagged even with no static references.
public class ObjcThing: NSObject {
    @objc public func ping() {}
}
