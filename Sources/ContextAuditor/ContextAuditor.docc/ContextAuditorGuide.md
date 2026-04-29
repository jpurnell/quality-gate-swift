# ContextAuditor Guide

A practical walkthrough of every ContextAuditor rule, with the pattern it flags and the recommended response.

## Why this auditor exists

Software that accesses location data, tracks user behavior, makes automated decisions about people, or runs background surveillance touches on fundamental questions of consent and transparency. These are not hypothetical concerns -- they are the source of real regulatory action, App Store rejections, and user trust erosion.

The compiler cannot help here. A call to `CLLocationManager()` is perfectly valid Swift. But if the surrounding function has no consent check, a reviewer should ask: does the user know this is happening?

ContextAuditor exists to surface these questions automatically. It is not a compliance tool and it does not know your product's consent flows. It is a heuristic that catches the most common shapes:

1. **Missing consent guards.** Sensitive APIs (location, contacts, camera, health, calendar, photos) accessed in a function that has no permission check.
2. **Unguarded analytics.** Event tracking fired without checking whether the user opted in.
3. **Automated decisions without review.** Code that predicts something about a user and then denies, blocks, or suspends them -- with no human in the loop.
4. **Surveillance patterns.** Background location tracking enabled without a disclosure annotation.

Every advisory can be suppressed with an inline annotation. The annotation is the point: it forces someone to write down *why* the pattern is acceptable.

## Rule walkthrough

### `context.missing-consent-guard`

This rule fires when a sensitive API type is instantiated or called inside a function body that contains no consent-related guard. The auditor looks for `guard` or `if` statements containing keywords like `consent`, `permission`, `authorization`, `hasLocation`, or `isAuthorized`. It also accepts a `// CONSENT:` annotation anywhere in the function body.

The sensitive types are: `CLLocationManager`, `CNContactStore`, `AVCaptureSession`, `HKHealthStore`, `EKEventStore`, and `PHPhotoLibrary`.

```swift
// Flagged -- no consent check in the function body
func startTracking() {
    let manager = CLLocationManager()
    manager.startUpdatingLocation()
}

// Accepted -- guard checks authorization status
func startTracking() {
    guard CLLocationManager.authorizationStatus() == .authorizedWhenInUse else {
        return
    }
    let manager = CLLocationManager()
    manager.startUpdatingLocation()
}

// Accepted -- if-statement checks permission
func fetchContacts() {
    if hasContactsPermission {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: [])
        try? store.enumerateContacts(with: request) { _, _ in }
    }
}

// Accepted -- CONSENT annotation with justification
func capturePhoto() {
    // CONSENT: Camera permission is requested and verified in OnboardingFlow
    // before this screen is reachable. See OnboardingFlow.swift:87.
    let session = AVCaptureSession()
    session.startRunning()
}
```

The auditor scopes its check to the enclosing function body. A consent guard at the top of the function satisfies all sensitive-API calls within it. Consent checks in a different function or file are invisible to this rule -- use a `// CONSENT:` annotation in those cases.

### `context.unguarded-analytics`

This rule fires when `Analytics.track(...)` is called in a function body that contains no opt-out guard. The auditor looks for any of these keywords in the function body: `isTrackingAllowed`, `trackingEnabled`, `analyticsEnabled`, `isOptedIn`, `optOut`. It also accepts a `// ANALYTICS:` annotation.

```swift
// Flagged -- no opt-out check
func onPurchaseComplete(item: String) {
    Analytics.track("purchase_complete", properties: ["item": item])
}

// Accepted -- opt-out guard present
func onPurchaseComplete(item: String) {
    guard isTrackingAllowed else { return }
    Analytics.track("purchase_complete", properties: ["item": item])
}

// Accepted -- tracking-enabled check
func onPurchaseComplete(item: String) {
    if analyticsEnabled {
        Analytics.track("purchase_complete", properties: ["item": item])
    }
}

// Accepted -- ANALYTICS annotation with justification
func onPurchaseComplete(item: String) {
    // ANALYTICS: Required for revenue reporting under SOX compliance.
    // User consent is verified at app launch; see ConsentManager.swift.
    Analytics.track("purchase_complete", properties: ["item": item])
}
```

This rule only matches the exact pattern `Analytics.track(...)`. Other analytics SDKs (Firebase, Mixpanel, Amplitude) are not currently detected. If your project uses a different analytics facade, the rule will not fire -- consider wrapping calls through an `Analytics.track` interface to get coverage.

### `context.automated-decision-without-review`

This rule fires when a function body contains both a prediction indicator (the word `predict`) and a denial action (`deny`, `block`, or `suspend`) without a `// REVIEWED:` annotation. The intent is to catch code that makes automated decisions affecting users -- loan denials, account suspensions, content blocking -- without a human review step.

```swift
// Flagged -- predicts risk and denies access with no review step
func evaluateLoanApplication(_ application: LoanApplication) -> Decision {
    let riskScore = model.predict(application.features)
    if riskScore > threshold {
        return .deny(reason: "Risk score exceeded threshold")
    }
    return .approve
}

// Accepted -- human review step is present and annotated
func evaluateLoanApplication(_ application: LoanApplication) -> Decision {
    let riskScore = model.predict(application.features)
    if riskScore > threshold {
        // REVIEWED: High-risk applications are queued for manual underwriter
        // review per policy FR-2024-03. Auto-deny only applies to scores
        // above 0.95, which represent < 0.1% of applications.
        return .deny(reason: "Risk score exceeded threshold")
    }
    return .approve
}

// Accepted -- routes to human review instead of auto-deciding
func evaluateLoanApplication(_ application: LoanApplication) -> Decision {
    let riskScore = model.predict(application.features)
    if riskScore > threshold {
        return .pendingReview(assignee: "underwriting-team")
    }
    return .approve
}
```

The heuristic is deliberately broad: any function that both predicts and denies/blocks/suspends deserves scrutiny. The `// REVIEWED:` annotation should explain either why automated decisions are acceptable or what human oversight exists.

Note that the third example above does not fire the rule because there is no `deny`, `block`, or `suspend` keyword -- the function routes to human review instead.

### `context.surveillance-pattern`

This rule fires when `allowsBackgroundLocationUpdates` is set to `true` without a `// DISCLOSURE:` annotation in the enclosing function body. Background location tracking is the canonical surveillance concern: the user may not realize their location is being tracked when the app is not visible.

```swift
// Flagged -- enables background tracking with no disclosure
func configureLocationManager() {
    let manager = CLLocationManager()
    manager.allowsBackgroundLocationUpdates = true
    manager.startUpdatingLocation()
}

// Accepted -- DISCLOSURE annotation explains the purpose
func configureLocationManager() {
    let manager = CLLocationManager()
    // DISCLOSURE: Background location is used for delivery driver tracking.
    // Users are informed via the "Active Delivery" banner and can end
    // tracking at any time. See privacy policy section 4.2.
    manager.allowsBackgroundLocationUpdates = true
    manager.startUpdatingLocation()
}
```

This rule intentionally has a narrow trigger: only the specific assignment `allowsBackgroundLocationUpdates = true` fires it. Other forms of background execution (background fetch, silent push notifications, background URLSession) are not currently detected.

Note that this rule may also trigger `context.missing-consent-guard` if `CLLocationManager()` is instantiated in the same function without a consent check. Both advisories can be addressed independently.

## How to suppress advisories

Every rule has a dedicated annotation keyword that suppresses it when present in the enclosing function body:

| Rule | Annotation | Placement |
|------|------------|-----------|
| `context.missing-consent-guard` | `// CONSENT: <reason>` | Anywhere in the function body |
| `context.unguarded-analytics` | `// ANALYTICS: <reason>` | Anywhere in the function body |
| `context.automated-decision-without-review` | `// REVIEWED: <reason>` | Anywhere in the function body |
| `context.surveillance-pattern` | `// DISCLOSURE: <reason>` | Anywhere in the function body |

The annotation must be a line comment (`//`), not a block comment (`/* */`). The text after the colon is freeform -- the auditor does not parse it -- but it should explain *why* the pattern is acceptable. Good annotations reference a specific consent flow, policy document, or architectural decision.

```swift
// Good -- references the consent flow location
// CONSENT: Permission requested in PermissionsViewController.requestCamera()

// Good -- references a policy
// REVIEWED: Auto-deny policy approved by compliance team, ref FR-2024-03

// Bad -- no justification
// CONSENT:

// Bad -- vague
// CONSENT: it's fine
```

The annotation is the documentation. When a future developer reads the code, the annotation tells them that someone considered the ethical dimension and made a deliberate, traceable choice. An empty or vague annotation defeats the purpose.

### Consent guard keywords

For the `context.missing-consent-guard` rule specifically, you can also satisfy the auditor by including a `guard` or `if` statement that contains any of these keywords:

- `consent` / `Consent`
- `permission` / `Permission`
- `authorization` / `Authorization`
- `hasLocation`
- `isAuthorized`

This means standard patterns like `guard isAuthorized else { return }` or `if hasLocationPermission` work without any special annotation.

### Analytics guard keywords

For `context.unguarded-analytics`, the auditor accepts any of these keywords anywhere in the function body (not limited to guard/if statements):

- `isTrackingAllowed`
- `trackingEnabled`
- `analyticsEnabled`
- `isOptedIn`
- `optOut`

## Living with advisories

ContextAuditor advisories are not bugs. They are flags that say: "a human should verify the ethical context here." The healthiest workflow is:

1. **See the advisory during quality-gate.** It appears as a warning, not an error.
2. **Decide whether it applies.** Does this code actually need a consent check? Is the analytics tracking already guarded elsewhere?
3. **Annotate or fix.** If the pattern is intentional, add the annotation with a real justification. If it reveals a genuine gap, add the consent check or opt-out guard.
4. **Move on.** The advisory will not appear again for annotated code.

If you find a rule firing on patterns that are never relevant to your codebase, consider whether the rule is miscalibrated for your domain. Open an issue describing the false positive pattern.
