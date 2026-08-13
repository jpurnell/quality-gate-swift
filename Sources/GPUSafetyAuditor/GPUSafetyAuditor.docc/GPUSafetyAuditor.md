# ``GPUSafetyAuditor``

Metal kernels that index by thread id with no bound, and the dispatch sites that create the surplus threads.

## Overview

Metal dispatches whole threadgroups. The universal idiom rounds up —
`(populationSize + 255) / 256` — so a grid of 1,200 elements dispatches 1,280
threads and eighty of them run the kernel body with nothing to stop them reading
and writing past every buffer.

Nothing fails. The command buffer reports success and the program returns
different numbers, which is why the symptom is a seeded optimiser that reproduces
*sometimes*. It is invisible at the sizes people test with: 1,024 elements
dispatch exactly 1,024 threads, so a test written at a power of two passes
forever.

## What it decides, and what it refuses to

| property | decidable |
|---|---|
| The thread id is never compared against any scalar the kernel was given | **yes** |
| The dispatch rounds up | **yes** |
| A comparison that *is* present uses the correct bound | **no** |
| An early `return` is safe in this kernel | **no** |

The last row is not pedantry. A tiled kernel bounds its writes and deliberately
has no early return, because out-of-range threads must keep reaching
`threadgroup_barrier` or the threads that do reach it wait forever. The naive
version of this rule flagged exactly such a kernel, and its suggested repair
would have converted correct code into a deadlock.

## Coverage is stated, never assumed

Every run prints what it read — `.metal` files, embedded literals, kernels
examined — including when the answer is zero. A checker that examined nothing
must not print what a checker that found nothing prints.

Both shader forms are read, because a project can exclude its `.metal` files from
every target and ship the live shaders as Swift string literals. Auditing only
`.metal` files there reports defects in code the compiler never sees while missing
every kernel that executes.

## A green result is not a proof

This finds kernels that are *certainly* wrong. It does not certify the rest.
`MTL_SHADER_VALIDATION=1` under the test suite catches what static analysis
cannot, including a guard that uses the wrong bound; the two are complementary,
since this one runs in seconds on a machine with no GPU.

## Topics

### Checker

- ``GPUSafetyAuditor``

### Rules

- ``KernelBoundsRule``
- ``DispatchRules``

### Shader discovery

- ``MetalKernel``
- ``MetalKernelParser``
- ``ShaderSourceLocator``
