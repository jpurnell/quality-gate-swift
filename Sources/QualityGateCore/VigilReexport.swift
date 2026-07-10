// swift-vigil extraction (Phase 4 §1, move-not-fork): the flip detector,
// test-outcome store, timing-test scanner, and temporal-determinism engine
// now live in VigilKit — one implementation, two products, with the monolith
// downstream of the extraction. Re-exported so every existing import site
// (TestRunner, the temporal wrapper, tests) stays source-stable.
@_exported import VigilKit
