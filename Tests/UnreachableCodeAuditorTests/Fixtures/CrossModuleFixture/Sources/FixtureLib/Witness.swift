public protocol Greeter {
    func greet() -> String
}

// `greet()` is a protocol witness — must NOT be flagged even though no
// code in the package directly calls it on `Hello`.
public struct Hello: Greeter {
    public init() {}
    public func greet() -> String { "hi" }
}
