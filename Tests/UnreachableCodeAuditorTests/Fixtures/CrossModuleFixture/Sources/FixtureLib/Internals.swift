// Should be flagged — internal, never referenced anywhere in the package.
func deadInternal() -> Int { 1 }

// Should NOT be flagged — referenced from FixtureExe/main.swift.
public func liveInternal() -> Int { 2 }
