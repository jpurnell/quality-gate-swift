// Phase 0.3 cutover shim: every type that lived in this module now has ONE
// implementation in CorpusKit (github.com/jpurnell/quality-gate-corpus-kit).
// The re-export keeps all existing `import IJSSensor` clients source-stable;
// remove opportunistically by importing CorpusKit directly.
@_exported import CorpusKit
