enum Status {
    case usedCase
    case deadCase
}

// `usedCase` is matched in the switch below; `deadCase` is never matched
// or constructed anywhere in the package and must be flagged.
public func runStatus() -> String {
    let s = Status.usedCase
    if case .usedCase = s { return "ok" }
    return "fallthrough"
}
