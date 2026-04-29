# ``MemoryLifecycleGuard``

Flags classes with resource ownership patterns that suggest missing cleanup.

## Overview

The Memory Lifecycle Guard detects two categories of lifecycle bugs that Swift's ARC does not catch: un-cancelled `Task` handles that leak work after deallocation, and strong delegate/parent references that create retain cycles.

This auditor walks `Sources/` only and skips `actor` types (which manage their own isolation). It uses SwiftSyntax to inspect class declarations for stored properties and `deinit` implementations.

## Rules

| Rule ID | Flags | Severity |
|---|---|---|
| `lifecycle-task-no-deinit` | Class with stored `Task` property but no `deinit` | warning |
| `lifecycle-task-no-cancel` | Class with stored `Task` property and `deinit` that doesn't call `.cancel()` | warning |
| `lifecycle-strong-delegate` | Stored property matching a delegate pattern without `weak` or `unowned` | warning |

## Exemptions

- `actor` types — managed isolation, different cancellation semantics
- `unowned` delegate properties — intentional non-weak reference
- Properties annotated with `// lifecycle:exempt`
- Computed properties (only stored properties are checked)
- Files in `Tests/` directories
- Files in configured `exemptFiles`

## Configuration

```yaml
memory-lifecycle:
  delegatePatterns: ["delegate", "parent", "owner", "dataSource"]
  requireTaskCancellation: true
  exemptFiles: []
```

## Topics

### Essentials

- ``MemoryLifecycleGuard``
- <doc:MemoryLifecycleGuardGuide>
