# ``IndexStoreInfra``

Shared infrastructure for cross-file Swift analysis using IndexStoreDB.

## Overview

IndexStoreInfra provides the foundation that quality-gate checkers use to move beyond single-file heuristics into project-wide analysis. It wraps Apple's IndexStoreDB library with project-aware session management, automatic index store location, and high-level query helpers for protocol conformance, symbol references, and call graph resolution.

## Topics

### Project Detection
- ``ProjectKind``

### Index Store Location
- ``StoreLocator``

### Session Management
- ``IndexStoreSession``

### Cross-File Queries
- ``ConformanceQuery``

### Source Enumeration
- ``SourceWalker``
