enum Status {
    case usedCase
    case deadCase
    case deadButLiveCase(progress: Double) // LIVE: intentional scaffolding for a future feature
}

// `usedCase` is matched in the switch below; `deadCase` is never matched
// or constructed anywhere in the package and must be flagged.
public func runStatus() -> String {
    let s = Status.usedCase
    if case .usedCase = s { return "ok" }
    return "fallthrough"
}
