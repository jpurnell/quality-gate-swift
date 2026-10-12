# ``ShapeMetrics``

Advisory ratios describing the shape of a codebase — verbosity and erosion — computed from
findings the gate has already produced rather than from a pass of its own.

## Overview

The checkers answer questions about correctness one finding at a time. A reader who wants to
know whether a package is getting harder to work in needs something else: a figure over the
whole tree, comparable between runs and between packages.

``ShapeMetrics`` builds those figures from what the run already found. Nothing here re-reads
the source; the contributing checkers do that, and this module aggregates the regions they
reported over a profile of the package's source lines. That is why every snapshot carries a
coverage note: a ratio computed when one of its contributors did not run is not the same
number as one computed when all of them did, and a bare `verbosity: 0.31` that cannot say
which is which cannot be acted on.

The metrics are advisory and always have been. They do not change a verdict, and no threshold
here fails a run — ``ShapeConfig`` carries the one knob that exists, and it selects which
regions count as complex, not whether the gate passes.

## Topics

### The snapshot

- ``ShapeSnapshot``
- ``ShapeReport``
- ``ShapeCoverage``

### The components

- ``VerbosityReport``
- ``ErosionReport``
- ``SLOCProfile``
- ``FlaggedRegion``

### Producing one

- ``ShapeMetricsPass``
- ``ShapeConfig``
