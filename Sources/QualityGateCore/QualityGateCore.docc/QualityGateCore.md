# ``QualityGateCore``

The foundational module for quality-gate-swift, providing shared protocols, models, and reporters.

## Overview

QualityGateCore defines the contract that all quality checkers implement, along with the data models for representing check results and the reporters for outputting those results in various formats.

### Key Concepts

- **QualityChecker**: Protocol that all checker modules implement
- **CheckResult**: The outcome of running a quality check
- **Diagnostic**: Individual issues found during checking
- **Reporter**: Formats results for different consumers (terminal, CI, GitHub)

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    QualityGateCore                       │
│                                                          │
│  ┌──────────────────┐    ┌──────────────────┐          │
│  │ QualityChecker   │───▶│   CheckResult    │          │
│  │    (protocol)    │    │                  │          │
│  └──────────────────┘    └────────┬─────────┘          │
│                                   │                     │
│                          ┌────────▼─────────┐          │
│                          │   Diagnostic     │          │
│                          │   (0 or more)    │          │
│                          └──────────────────┘          │
│                                                          │
│  ┌──────────────────┐    ┌──────────────────┐          │
│  │  Configuration   │    │     Reporter     │          │
│  │  (.quality-gate  │    │  Terminal/JSON/  │          │
│  │      .yml)       │    │     SARIF        │          │
│  └──────────────────┘    └──────────────────┘          │
└─────────────────────────────────────────────────────────┘
```

## Topics

### Essentials

- ``QualityChecker``
- ``CheckResult``
- ``Diagnostic``

### Configuration

- ``Configuration``

### Error Handling

- ``QualityGateError``

### Reporters

- ``Reporter``
- ``TerminalReporter``
- ``JSONReporter``
- ``SARIFReporter``
- ``OutputFormat``
- ``ReporterFactory``

### Guides

- <doc:ImplementingCheckers>
