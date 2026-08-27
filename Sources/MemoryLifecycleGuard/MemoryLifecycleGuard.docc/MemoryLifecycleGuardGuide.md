# Getting Started with MemoryLifecycleGuard


## Overview

The Memory Lifecycle Guard catches resource ownership bugs that compile fine but leak work or create retain cycles at runtime.

## What It Detects

### Un-cancelled Task Handles (`lifecycle-task-no-deinit`)

A class that stores a `Task` but has no `deinit` leaks work — the task continues running after the owning object is deallocated:

```swift
func poll() async { }

// WARNING: lifecycle-task-no-deinit
class Coordinator {
    var pollingTask: Task<Void, Never>?

    func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
```

The fix is to add a `deinit` that cancels the task (`CancellingCoordinator` below is the
same class with that one addition):

```swift
// PASSES
class CancellingCoordinator {
    var pollingTask: Task<Void, Never>?

    func startPolling() {
        pollingTask = Task { await poll() }
    }

    deinit {
        pollingTask?.cancel()
    }
}
```

### Missing Cancel in Deinit (`lifecycle-task-no-cancel`)

Having a `deinit` isn't enough — it must actually cancel the task:

```swift
// WARNING: lifecycle-task-no-cancel
class Worker {
    var task: Task<Void, Never>?
    deinit {
        print("Worker deallocated")  // forgot to cancel!
    }
}
```

### Strong Delegate References (`lifecycle-strong-delegate`)

Non-weak delegate properties create retain cycles:

```swift
protocol ViewControllerDelegate: AnyObject { }
protocol TableDataSource: AnyObject { }

// WARNING: lifecycle-strong-delegate
class ViewController {
    var delegate: ViewControllerDelegate?
    var dataSource: TableDataSource?
}

// PASSES
class WeakDelegateViewController {
    weak var delegate: ViewControllerDelegate?
    weak var dataSource: TableDataSource?
}
```

The default delegate patterns are: `delegate`, `parent`, `owner`, `dataSource`.

## Exemptions

Actors are exempt — they have different lifecycle semantics:

```swift
// Not flagged — actor manages its own isolation
actor NetworkMonitor {
    var task: Task<Void, Never>?
}
```

Use `// lifecycle:exempt` for intentional patterns:

```swift
class Engine {
    var renderTask: Task<Void, Never>? // lifecycle:exempt — managed by scene lifecycle
}
```

## Configuration

Customize delegate patterns or disable Task cancellation checks:

```yaml
memory-lifecycle:
  delegatePatterns: ["delegate", "parent", "owner", "dataSource", "coordinator"]
  requireTaskCancellation: true
  exemptFiles:
    - Sources/Legacy/ObjCBridge.swift
```

## Integration

```bash
# Run standalone
quality-gate --check memory-lifecycle

# Include in full gate
quality-gate --check all --strict
```
