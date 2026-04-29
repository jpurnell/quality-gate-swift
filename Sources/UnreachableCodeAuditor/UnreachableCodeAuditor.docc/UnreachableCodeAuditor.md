# ``UnreachableCodeAuditor``

Detects dead code through a two-pass architecture: a syntactic pass (SwiftSyntax) for intra-file patterns and a cross-module pass (IndexStore + BFS reachability) for whole-program dead symbols.

## Overview

UnreachableCodeAuditor is the most architecturally involved checker in the quality-gate suite. Unlike the other auditors, which are purely syntactic and operate on a single file at a time, this one combines two fundamentally different analysis strategies into a single gate result.

**Pass 1 -- Syntactic (always runs).** A SwiftSyntax `SyntaxVisitor` walks every `.swift` file under the project root. It catches three patterns without any build artifacts: statements after an unconditional terminator (`return`, `throw`, `break`, `continue`, `fatalError`, `preconditionFailure`), branches of constant boolean conditions (`if false { ... }`, `if true { ... } else { ... }`), and private/fileprivate symbols never referenced in the same file. This pass is fast, zero-configuration, and works on any Swift codebase layout.

**Pass 2 -- Cross-module (requires IndexStore).** The auditor locates or builds an IndexStoreDB database, collects every checkable definition (functions, methods, properties, enum cases), identifies a root set of entry points, builds a caller-to-callee graph, and BFS-walks reachability from the roots. Any checkable symbol the walk does not reach -- and that also has zero external references in the index -- is flagged as unreachable. The conservative double-gate (BFS *and* zero refs) eliminates false positives from missing call-graph edges at the cost of not detecting dead chains. Project kind detection (SwiftPM, Xcode project, Xcode workspace, plain directory) determines how the index store is located or built.

The design philosophy is: the syntactic pass should never false-positive (it sees exactly what the code says), while the cross-module pass should false-positive as rarely as possible (it accepts more escape hatches in exchange for fewer bad flags). When the cross-module pass cannot run -- no index store, stale build, unsupported project kind -- it emits a `.note` and the gate does not fail.

### Detected rules

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `unreachable.after_terminator` | error | Statements following an unconditional terminator (`return`, `throw`, `break`, `continue`, `fatalError()`, `preconditionFailure()`) |
| `unreachable.dead_branch` | error | Branches guarded by a constant boolean (`if false { ... }` or `else` after `if true`) |
| `unreachable.unused_private` | warning | Private/fileprivate symbols with zero references in the same file |
| `unreachable.cross_module.unreachable_from_entry` | error | Symbols unreachable from any entry point via BFS and with zero external index references |
| `unreachable.cross_module.skipped` | note | Cross-module pass could not run (no index store, build failure, plain directory) |
| `unreachable.cross_module.stale` | note | Located index store is older than the newest source file |

### Root set (what counts as an entry point)

The cross-module pass seeds BFS from these categories. If a symbol matches any of them, it is considered live without needing an incoming call edge:

- **Public/open API in library targets** -- the module's exported surface.
- **Test targets** -- every symbol in a target whose type is `"test"` (or whose module name ends in `Tests`/`UITests`).
- **Unit test properties** -- symbols marked `.unitTest` by the index.
- **`@main` types and their members** -- the program entry point.
- **`@objc`, `@IBAction`, `@IBOutlet`, `@_cdecl`, `@_silgen_name`** -- dynamic dispatch and C interop.
- **Initializers** -- conservatively rooted because the type's own reachability is not yet modeled precisely.
- **`CodingKey` enum cases** -- referenced only by compiler-synthesized `Codable` machinery invisible to the index.
- **Protocol witnesses** -- detected via `overrideOf`/`baseOf` index relations and via the `WellKnownWitnesses` allow-list (1860+ requirement names across 378 Apple framework protocols, auto-regenerated weekly from Swift toolchain symbol graphs).
- **`// LIVE:` exemptions** -- a comment on the declaration line or the line above.
- **Top-level statements in `main.swift`** -- anything they call is promoted to a root.

### Liveness index and call-graph construction

`LivenessIndex` ingests every source file via SwiftSyntax to collect per-declaration facts (`DeclFact`) and lexical ranges (`DeclRange`). Facts record visibility, attribute markers (`@objc`, `@main`), and whether the declaration is an init, enum case, or CodingKey. Ranges record the start/end lines and the "name line" (the line IndexStoreDB records for the definition occurrence).

The call graph is built by iterating every reference/call/read/write occurrence in the index, looking up the enclosing declaration *lexically* via `LivenessIndex.enclosingDeclNameLine` rather than relying on IndexStoreDB's `.containedBy`/`.calledBy` relations (which are unreliable for static methods, stored-property reads, generics, computed-property accessors, and closures). This lexical approach is the key design decision that makes the graph accurate enough to be useful.

### Configuration

The auditor reads these fields from `Configuration`:

- `excludePatterns` -- glob patterns for files to skip (both passes honor this).
- `unreachableAutoBuildXcode` -- opt-in: run `xcodebuild build` when no fresh index store exists for Xcode projects.
- `xcodeScheme` -- override the auto-detected scheme for `xcodebuild`.
- `xcodeDestination` -- override the build destination (default `"generic/platform=macOS"`).

### Project kind detection

`ProjectKind.detect(at:)` probes the root directory in priority order: `Package.swift` (SwiftPM) > `*.xcworkspace` > `*.xcodeproj` > plain. SwiftPM projects get an automatic index build into `.build/index-build/index-store`. Xcode projects look up existing entries under `~/Library/Developer/Xcode/DerivedData/` by matching the sanitized project name and validating the `info.plist` workspace path. Plain directories run only the syntactic pass.

### Macro and synthesized symbol filtering

Compiler- and macro-generated symbols (`_$observationRegistrar`, `@Observable` accessors, memberwise inits with `:` in their name) are silently skipped by `IndexStorePass.looksMacroGenerated`. Symbols with no `DeclFact` (compiler-synthesized through paths the visitor does not handle) are also skipped to prevent false positives.

### Out of scope

- Dead type detection (only functions, methods, properties, and enum cases are checkable).
- Dead-chain detection (the conservative double-gate requires zero refs, so `A -> B -> C` where only `A` is unreachable will flag `A` but not `B` or `C`).
- Cross-module analysis for plain directories (no build system, no index store).
- Protocol conformance witness detection across module boundaries without the `WellKnownWitnesses` allow-list.
- Interprocedural analysis through closures stored in variables.

## Topics

### Essentials

- ``UnreachableCodeAuditor/check(configuration:)``
- ``UnreachableCodeAuditor/audit(at:configuration:)``
- ``UnreachableCodeAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:UnreachableCodeAuditorGuide>
