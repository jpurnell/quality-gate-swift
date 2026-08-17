# ``LivenessAuditor``

Blocking waits that declined a deadline their own API offered.

## Overview

A `DispatchSemaphore` has two ways to wait. One of them takes a deadline. When the call site uses
the other, nothing marks the choice — the code reads as ordinary, and the program acquires a way
to stop forever that no one decided on.

This checker reports exactly that: **the vendor provided a bounded overload and this call site did
not use it.** The claim is small on purpose. It is decidable from the overload set rather than from
reasoning about the program, so a finding is never a matter of opinion and the repair is always
available — the API is already holding it.

What the checker does *not* claim is that the code cannot hang. Whether a wait is genuinely
bounded depends on subprocess lifetime, signal delivery, descriptor inheritance, thread
scheduling, and whether a timeout handler is even reachable after the wait returns. None of that
is visible to a syntactic pass, and a checker that implied otherwise would be issuing clean
verdicts about hangs. Primitives with no bounded form at all — `readDataToEndOfFile()`,
`waitUntilExit()` — are a different problem, handled by confining them to an audited kernel rather
than by reasoning about them.

## Why this checker exists

`ProcessSafetyAuditor` was written to catch a pipe deadlock and matched one syntactic shape of it.
Over the next three months the same file acquired two more deadlocks, and it caught neither. The
third cost forty-six minutes of silence and then blocked the commit of its own fix.

The narrower lesson is that a rule matched a shape instead of a hazard. The broader one is that the
checker was scoped to a *subsystem* — processes — when the hazard was *waiting without a bound*.
The first two findings of this checker are semaphore waits in a terminal UI, with no subprocess
anywhere near them. No amount of improvement to a process-safety checker would ever have reached
them.

## What a pass means

Every run prints what it examined, including when it finds nothing:

```
liveness examined 5 blocking waits against 3 known primitives across 640 files
```

The count is there because this checker's predecessor passed for months and its silence was read
as a guarantee it had never made. When a receiver's type cannot be resolved from the file, the
call is skipped rather than guessed at, and the skipped count is printed too — a green run should
state its own blind spot rather than conceal it.

## What is deliberately absent

`NSLock` offers `lock(before:)`, so by the stated principle it belongs in the table. It is excluded
anyway. Every `lock()` in this repository is the conventional `lock(); defer { unlock() }` critical
section, and reporting those would be a false positive on the most ordinary pattern in Swift.

The line is not expedience. These primitives wait for an **event that may never occur** — a `Task`
that never completes. A lock waits for **mutual exclusion**, bounded by a critical section in the
same program. Lock-ordering deadlock is a real hazard that needs lock-order analysis, and it must
not be smuggled into a rule that cannot perform it.

## Topics

### Checker

- ``LivenessAuditor``
