# ``AppIntentsAuditor``

Audits Apple App Intents declarations for completeness, discoverability, and Apple Intelligence readiness.

## Overview

AppIntentsAuditor is an opt-in quality-gate checker that analyzes Swift source files using the `AppIntents` framework. It detects missing metadata that would prevent intents, entities, and enums from surfacing in Shortcuts, Spotlight, and Siri -- and from qualifying for Apple Intelligence integration.

Enable it in `.quality-gate.yml`:

```yaml
appIntentsReadiness:
  enabled: true
```

## Topics

### Core Analysis
- ``AppIntentVisitor``
- ``AppIntentsAuditor``

### Extracted Types
- ``ExtractedIntent``
- ``ExtractedParameter``
- ``ExtractedEntity``
- ``ExtractedEnum``
