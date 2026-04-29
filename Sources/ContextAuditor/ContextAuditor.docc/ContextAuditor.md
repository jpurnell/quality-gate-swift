# ``ContextAuditor``

An advisory ethical context checker that surfaces potential consent, analytics, surveillance, and automated-decision concerns in Swift source code.

## Overview

ContextAuditor uses SwiftSyntax to walk Swift source files and flag code patterns that raise ethical concerns -- sensitive API access without consent guards, analytics tracking without opt-out checks, automated decisions that affect users without human review, and background tracking without disclosure.

**This auditor is advisory.** Every diagnostic it emits has severity `.warning`, never `.error`. It will never break your build or block your commit. Its purpose is to surface patterns that deserve a second look -- not to enforce a single ethical framework. Teams should treat these advisories as conversation starters during code review, not as verdicts.

The auditor skips test files entirely (any path containing `Tests/` or `XCTests/`), since test code frequently exercises sensitive APIs without production consent flows.

### Detected rules

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `context.missing-consent-guard` | warning | Sensitive API (location, contacts, camera, health, calendar, photos) accessed without a consent or permission check in the enclosing function |
| `context.unguarded-analytics` | warning | `Analytics.track(...)` called without an opt-out guard (`isTrackingAllowed`, `optOut`, etc.) in the enclosing function |
| `context.automated-decision-without-review` | warning | A function body that contains both a prediction (`predict`) and a denial action (`deny`, `block`, `suspend`) without a `// REVIEWED:` annotation |
| `context.surveillance-pattern` | warning | `allowsBackgroundLocationUpdates = true` set without a `// DISCLOSURE:` annotation in the enclosing function |

### Advisory nature

Unlike the safety, concurrency, recursion, and pointer-escape auditors -- which flag patterns that are objectively wrong -- ContextAuditor flags patterns that are *contextually* concerning. A `CLLocationManager()` call is not a bug. It may, however, be a consent gap if the surrounding function has no permission check.

Because context is inherently ambiguous, the auditor errs on the side of silence:

- It only checks production source files under `Sources/`.
- It scopes every check to the enclosing function body, so a consent guard at the top of the function satisfies all sensitive-API calls within it.
- Every rule has a lightweight annotation escape hatch (`// CONSENT:`, `// ANALYTICS:`, `// REVIEWED:`, `// DISCLOSURE:`) that suppresses the advisory with a human-readable justification.

If a rule fires on code that is genuinely fine, annotate it. The annotation is the documentation that someone thought about the ethical dimension and made a deliberate choice.

### Configuration

ContextAuditor reads no external configuration. It is enabled by default when included in the quality-gate pipeline and produces only warnings.

Suppression is per-call-site via inline annotations:

| Rule | Annotation keyword |
|------|--------------------|
| `context.missing-consent-guard` | `// CONSENT:` (or a `guard`/`if` containing consent/permission/authorization keywords) |
| `context.unguarded-analytics` | `// ANALYTICS:` (or the presence of `isTrackingAllowed`, `analyticsEnabled`, `optOut`, etc.) |
| `context.automated-decision-without-review` | `// REVIEWED:` |
| `context.surveillance-pattern` | `// DISCLOSURE:` |

### Sensitive API types

The following types are considered sensitive and trigger the `missing-consent-guard` rule when instantiated or called:

- `CLLocationManager` -- Location services
- `CNContactStore` -- Contacts access
- `AVCaptureSession` -- Camera/microphone capture
- `HKHealthStore` -- HealthKit data
- `EKEventStore` -- Calendar/reminders access
- `PHPhotoLibrary` -- Photo library access

### Out of scope

- Cross-file consent flow analysis (a consent check in a different file won't satisfy the auditor; it only sees the current function body)
- Third-party analytics SDKs beyond the `Analytics.track(...)` pattern
- GDPR/CCPA compliance verification (this is a code-level heuristic, not a legal tool)
- Network request auditing for data exfiltration patterns
- Detecting consent checks that use non-standard naming conventions outside the built-in keyword list

## Topics

### Essentials

- ``ContextAuditor/check(configuration:)``
- ``ContextAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:ContextAuditorGuide>
