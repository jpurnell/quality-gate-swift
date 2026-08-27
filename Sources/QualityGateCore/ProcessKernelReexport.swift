// `ProcessRunner` used to live in this module, at
// `Sources/QualityGateCore/ProcessRunner.swift`. It is now
// `jpurnell/swift-process-kernel`, and re-exported here.
//
// Re-exported rather than imported target by target because nothing about the
// runner was quality-gate-specific and nothing about its callers changed: the
// 23 call sites across 18 targets already say `ProcessRunner.run(…)`, and they
// reach it through this module exactly as before. Making each of those targets
// name the dependency would be 18 Package.swift edits to relocate a symbol none
// of them chose the home of.
//
// The move exists because the runner could not be shared. Anything wanting it
// had to depend on the whole gate, and `quality-gate-swift` depends on
// `swift-vigil` — so vigil adopting it would have closed a cycle, leaving the
// bounded-io rule unsatisfiable in the one repository that most needed it.
@_exported import ProcessKernel
