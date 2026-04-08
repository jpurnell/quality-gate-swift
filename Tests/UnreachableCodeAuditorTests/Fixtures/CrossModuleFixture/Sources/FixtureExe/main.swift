import FixtureLib

// Top-level statements in main.swift seed the reachability roots:
// every symbol referenced from here is treated as live.
let n = liveInternal()
print(n)
liveChainX()

// Should be flagged — private to the executable, never called.
private func deadInExe() {}
