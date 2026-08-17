# ``BoundedIOAuditor``

Unbounded blocking primitives called outside the audited kernel.

## Overview

Some blocking calls have no bounded form. `readDataToEndOfFile()` returns at EOF or never, and
EOF arrives only when every write end closes — including copies held by grandchildren the code
never sees. No overload takes a deadline, so the call can only be bounded from outside.

Deciding whether any particular one *is* bounded would mean modelling subprocess lifetime,
process groups, signal delivery, descriptor inheritance, thread scheduling, and whether a timeout
handler is even reachable after the wait. No syntactic pass discharges that, and one appearing to
would be worse than none — it would issue clean verdicts about hangs.

So this checker asks a different question, one it can actually answer: **is this called outside
the kernel?** That is the trade an `unsafe` block makes. Confine what cannot be proven, and audit
the confinement by hand.

## Why a kernel is worth more than the checking

The deadline fix that prompted this landed on **one of nine sites**. There was no kernel for a
correct fix to propagate from, so repairing the shared runner repaired one caller and left eight
untouched. Containment does not make the kernel correct — the kernel was wrong for three months.
It makes the kernel the only place that has to be, and small enough to carry a regression corpus
of every hang yet found.

## Acknowledgements

`// Unbounded: <reason>` on the line immediately above removes the error and counts the site into
the coverage note. A bare marker with no reason does not qualify, and that is the load-bearing
part: when the justification cannot be written honestly, the inability to write it is the
finding. `PluginRunner` armed a watchdog that terminated the child and did not bound the read;
no true sentence described it as bounded.

## Topics

### Checker

- ``BoundedIOAuditor``
