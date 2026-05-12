# Design Proposal: Structural Observability System

**Date:** 2026-04-30 (revised 2026-05-05)
**Status:** Approved — ready for UPCOMING
**Author:** Justin Purnell + Claude Opus 4.6

---

## 1. Objective

**Problem:** AI-generated code is functionally correct but operationally blind. When a consumer-facing app has a long load time or silent pipeline failure, there's no structured logging to diagnose it. Debugging devolves into speculative print-insertion and circular hypothesis testing.

**Why v1 Failed (before implementation):** The first draft of this proposal tried to enforce a design pattern (observable code) with a syntax checker. The adversarial review correctly identified that an AST-based linter can't reliably detect "missing logging" — it would produce false positives on utility functions and false negatives on functions with non-standard I/O patterns. Four of the seven proposed instrumentation points were acknowledged as unenforeable by the auditor and deferred to "behavioral guidance" (CLAUDE.md), which is just documentation the AI might ignore.

**The architectural insight:** If logging is something you *add* to each function, it will be forgotten. If logging is *structural* — baked into the types you use to perform I/O, transform data, and manage state — it cannot be forgotten. The auditor's job then shifts from "detect missing logging" (hard, heuristic, noisy) to "detect bypass of instrumented types" (simple, deterministic, near-zero false positives).

**This proposal delivers four artifacts:**

| # | Deliverable | Purpose |
|---|-------------|---------|
| 1 | **Instrumentation Primitives** | Swift types that make logging automatic: `InstrumentedClient`, `Pipeline`, `@Logged`, `withObservability` |
| 2 | **Coding Rules** (`00_CORE_RULES/13_LOGGING_INSTRUMENTATION.md`) | Mandate the instrumented types; ban raw I/O in application code |
| 3 | **CLAUDE.md Additions** | Standing instruction to use instrumented types by default |
| 4 | **LoggingAuditor v2** | Detect bypass of instrumented types (not missing logging) |

---

## 2. Proposed Architecture

### Design Principle: The Logged Path is the Only Path

The system works by making the instrumented API the path of least resistance and then detecting when someone goes around it. Three layers:

```
┌─────────────────────────────────────────────┐
│  Layer 1: Instrumentation Primitives        │
│  (Swift types that auto-log)                │
│                                             │
│  InstrumentedClient  Pipeline  @Logged      │
│  withObservability   ResourceScope          │
└────────────────┬────────────────────────────┘
                 │ uses
┌────────────────▼────────────────────────────┐
│  Layer 2: Coding Rules + CLAUDE.md          │
│  (Mandate instrumented types, ban raw I/O)  │
└────────────────┬────────────────────────────┘
                 │ enforced by
┌────────────────▼────────────────────────────┐
│  Layer 3: LoggingAuditor v2                 │
│  (Detect bypass — raw URLSession, raw       │
│   FileManager, etc.)                        │
└─────────────────────────────────────────────┘
```

### Where the Primitives Live

**Option A: Standalone package** (`swift-observability` or similar)
- Projects add it as an SPM dependency
- Single source of truth for primitive implementations
- Updates propagate via version bumps
- Adds a dependency to every project

**Option B: Reference implementations in coding rules**
- Patterns defined in `13_LOGGING_INSTRUMENTATION.md` with copy-paste-ready code
- Each project adapts to its needs
- Zero external dependencies
- Drift risk between projects

**Recommendation:** Option A for production use — a lightweight package with zero external dependencies (only `import os`). The coding rules reference it and show usage. Projects that can't take the dependency can copy the patterns (Option B as fallback).

---

## 3. API Surface

### Primitive 1: `InstrumentedClient` — Network I/O

Wraps `URLSession` so that every network request is automatically logged with timing, status, and error context. Application code never touches `URLSession` directly.

```swift
import os

public actor InstrumentedClient {
    private let session: URLSession
    private let logger: Logger

    public init(
        session: URLSession = .shared,
        subsystem: String? = nil,
        category: String = "Network"
    ) {
        self.session = session
        self.logger = Logger(
            subsystem: subsystem ?? Bundle.main.bundleIdentifier ?? "app",
            category: category
        )
    }

    /// Fetch data from a URL. Automatically logs request, response, timing, and errors.
    public func data(from url: URL) async throws -> (Data, URLResponse) {
        let host = url.host(percentEncoded: false) ?? "unknown"
        let path = url.path(percentEncoded: false)
        logger.info("Request: GET \(host, privacy: .public)\(path, privacy: .public)")
        let start = ContinuousClock.now

        do {
            let (data, response) = try await session.data(from: url)
            let elapsed = start.duration(to: .now)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Response: \(statusCode, privacy: .public) — \(data.count, privacy: .public) bytes in \(elapsed, privacy: .public)")
            return (data, response)
        } catch {
            let elapsed = start.duration(to: .now)
            logger.error("Request failed after \(elapsed, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Fetch data for a URLRequest. Automatically logs method, URL, timing, and errors.
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        let host = request.url?.host(percentEncoded: false) ?? "unknown"
        let path = request.url?.path(percentEncoded: false) ?? "/"
        logger.info("Request: \(method, privacy: .public) \(host, privacy: .public)\(path, privacy: .public)")
        let start = ContinuousClock.now

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = start.duration(to: .now)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Response: \(statusCode, privacy: .public) — \(data.count, privacy: .public) bytes in \(elapsed, privacy: .public)")
            return (data, response)
        } catch {
            let elapsed = start.duration(to: .now)
            logger.error("Request failed after \(elapsed, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Download file from URL. Logs progress and destination.
    public func download(from url: URL) async throws -> (URL, URLResponse) {
        let host = url.host(percentEncoded: false) ?? "unknown"
        logger.info("Download started: \(host, privacy: .public)")
        let start = ContinuousClock.now

        do {
            let (localURL, response) = try await session.download(from: url)
            let elapsed = start.duration(to: .now)
            logger.info("Download complete in \(elapsed, privacy: .public)")
            return (localURL, response)
        } catch {
            let elapsed = start.duration(to: .now)
            logger.error("Download failed after \(elapsed, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
```

**Usage in application code:**

```swift
// ✅ REQUIRED: All network I/O through instrumented client
let client = InstrumentedClient()
let (data, response) = try await client.data(from: profileURL)

// ❌ BANNED: Raw URLSession in application code
let (data, response) = try await URLSession.shared.data(from: profileURL)
```

**What the logs look like at runtime:**

```
[Network] Request: GET api.example.com/v2/profile
[Network] Response: 200 — 4328 bytes in 0.847s
```

When debugging a slow load: you instantly see which request took 4 seconds instead of 0.8.

---

### Primitive 2: `Pipeline` — Data Transformation Chains

A result builder that creates a logged multi-stage data pipeline. Each stage automatically logs its name, input/output counts, timing, and any items dropped.

```swift
import os

/// A named stage in a data pipeline that transforms a collection.
public struct Stage<Input, Output> {
    public let name: String
    public let transform: ([Input]) async throws -> [Output]

    public init(_ name: String, transform: @escaping ([Input]) async throws -> [Output]) {
        self.name = name
        self.transform = transform
    }
}

/// A logged data pipeline that reports stage-by-stage progress.
public struct Pipeline<Final> {
    private let logger: Logger
    private let name: String
    private let execute: () async throws -> [Final]

    /// Execute the pipeline, logging each stage.
    public func run() async throws -> [Final] {
        logger.info("Pipeline '\(name, privacy: .public)' started")
        let start = ContinuousClock.now

        do {
            let result = try await execute()
            let elapsed = start.duration(to: .now)
            logger.info("Pipeline '\(name, privacy: .public)' complete: \(result.count, privacy: .public) items in \(elapsed, privacy: .public)")
            return result
        } catch {
            let elapsed = start.duration(to: .now)
            logger.error("Pipeline '\(name, privacy: .public)' failed after \(elapsed, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// Build a two-stage pipeline with automatic inter-stage logging.
///
/// Each stage logs: name, input count, output count, items dropped, and timing.
/// The pipeline logs: total name, final count, and total elapsed time.
///
/// - Parameters:
///   - name: Pipeline name for log messages.
///   - logger: Logger instance to use.
///   - source: Async closure that produces the initial data.
///   - stage1: First transformation stage.
///   - stage2: Second transformation stage.
/// - Returns: A Pipeline whose `run()` executes all stages with logging.
public func makePipeline<A, B, Final>(
    name: String,
    logger: Logger,
    source: @escaping () async throws -> [A],
    _ stage1: Stage<A, B>,
    _ stage2: Stage<B, Final>
) -> Pipeline<Final> {
    Pipeline(logger: logger, name: name) {
        let raw = try await source()
        logger.debug("[\(name, privacy: .public)] Source: \(raw.count, privacy: .public) items")

        let stageStart1 = ContinuousClock.now
        let after1 = try await stage1.transform(raw)
        let elapsed1 = stageStart1.duration(to: .now)
        logger.debug("[\(name, privacy: .public)] \(stage1.name, privacy: .public): \(raw.count, privacy: .public) → \(after1.count, privacy: .public) in \(elapsed1, privacy: .public)")

        let stageStart2 = ContinuousClock.now
        let after2 = try await stage2.transform(after1)
        let elapsed2 = stageStart2.duration(to: .now)
        logger.debug("[\(name, privacy: .public)] \(stage2.name, privacy: .public): \(after1.count, privacy: .public) → \(after2.count, privacy: .public) in \(elapsed2, privacy: .public)")

        return after2
    }
}
```

**Usage:**

```swift
let feedPipeline = makePipeline(
    name: "FeedRefresh",
    logger: logger,
    source: { try await api.fetchRawFeed() },
    Stage("decode") { raw in try raw.compactMap { try? decoder.decode(FeedItem.self, from: $0) } },
    Stage("validate") { items in items.filter { $0.isValid } }
)

let items = try await feedPipeline.run()
```

**What the logs look like:**

```
[FeedRefresh] Pipeline 'FeedRefresh' started
[FeedRefresh] Source: 250 items
[FeedRefresh] decode: 250 → 243 in 0.012s
[FeedRefresh] validate: 243 → 238 in 0.003s
[FeedRefresh] Pipeline 'FeedRefresh' complete: 238 items in 0.891s
```

When debugging "where did my data go?": you see exactly which stage dropped records.

---

### Primitive 3: `@Logged` — State Transitions

A property wrapper that logs every mutation with old and new values.

```swift
import os

/// Property wrapper that logs state transitions via os.Logger.
///
/// Every set operation logs the old and new value at `.notice` level.
/// Values must conform to `CustomStringConvertible` for log output.
///
/// ```swift
/// @Logged(name: "authState", logger: appLogger)
/// var authState: AuthState = .unauthenticated
/// // Setting authState logs: "authState: unauthenticated → authenticated"
/// ```
@propertyWrapper
public struct Logged<Value: CustomStringConvertible & Equatable> {
    private var value: Value
    private let name: String
    private let logger: Logger

    public init(wrappedValue: Value, name: String, logger: Logger) {
        self.value = wrappedValue
        self.name = name
        self.logger = logger
        logger.notice("\(name, privacy: .public) initialized: \(wrappedValue.description, privacy: .public)")
    }

    public var wrappedValue: Value {
        get { value }
        set {
            guard newValue != value else { return }
            let oldDescription = value.description
            value = newValue
            logger.notice("\(name, privacy: .public): \(oldDescription, privacy: .public) → \(newValue.description, privacy: .public)")
        }
    }
}
```

**Usage:**

```swift
class AppCoordinator {
    private let logger = Logger(subsystem: "com.app", category: "AppState")

    @Logged(name: "appState", logger: logger)
    var appState: AppState = .launching
}

// Setting appState automatically logs:
// [AppState] appState: launching → loading
// [AppState] appState: loading → ready
```

**What the logs look like when debugging "how did we get here?":**

```
[AppState] appState initialized: launching
[AppState] appState: launching → loadingProfile
[AppState] appState: loadingProfile → loadingFeed
[AppState] appState: loadingFeed → ready        ← 4.2s gap here is your load time bug
```

---

### Primitive 4: `withObservability` — Operation Wrapper

A function-level wrapper for operations that don't fit the other primitives. Handles timing, error logging, and catch-block instrumentation in one call.

```swift
import os

/// Execute an operation with automatic entry/exit logging and error capture.
///
/// Use this for any significant async operation that isn't covered by
/// `InstrumentedClient` (network) or `Pipeline` (data transforms).
///
/// Errors are logged and rethrown — the caller's catch block doesn't need
/// separate error logging because `withObservability` already did it.
///
/// ```swift
/// let profile = try await withObservability("loadProfile", logger: logger) {
///     try await profileStore.fetch(userId)
/// }
/// ```
public func withObservability<T>(
    _ name: String,
    logger: Logger,
    level: OSLogType = .info,
    _ operation: () async throws -> T
) async throws -> T {
    logger.log(level: level, "\(name, privacy: .public) started")
    let start = ContinuousClock.now

    do {
        let result = try await operation()
        let elapsed = start.duration(to: .now)
        logger.log(level: level, "\(name, privacy: .public) completed in \(elapsed, privacy: .public)")
        return result
    } catch {
        let elapsed = start.duration(to: .now)
        logger.error("\(name, privacy: .public) failed after \(elapsed, privacy: .public): \(error.localizedDescription, privacy: .public)")
        throw error
    }
}

/// Non-throwing variant for operations that return Optional on failure.
public func withObservability<T>(
    _ name: String,
    logger: Logger,
    level: OSLogType = .info,
    _ operation: () async -> T?
) async -> T? {
    logger.log(level: level, "\(name, privacy: .public) started")
    let start = ContinuousClock.now

    guard let result = await operation() else {
        let elapsed = start.duration(to: .now)
        logger.warning("\(name, privacy: .public) returned nil after \(elapsed, privacy: .public)")
        return nil
    }

    let elapsed = start.duration(to: .now)
    logger.log(level: level, "\(name, privacy: .public) completed in \(elapsed, privacy: .public)")
    return result
}
```

**Usage:**

```swift
// Instead of manually logging entry/exit/errors:
func loadUserData() async throws -> UserData {
    let profile = try await withObservability("fetchProfile", logger: logger) {
        try await profileService.fetch(userId)
    }
    let preferences = try await withObservability("fetchPreferences", logger: logger) {
        try await prefsService.fetch(userId)
    }
    return UserData(profile: profile, preferences: preferences)
}
```

**What the logs look like:**

```
[UserData] fetchProfile started
[UserData] fetchProfile completed in 0.340s
[UserData] fetchPreferences started
[UserData] fetchPreferences failed after 2.001s: timeout
```

No manual catch-block logging needed — `withObservability` already logged the error with context and timing.

---

### Primitive 5: `ResourceScope` — Resource Lifecycle

Tracks acquisition and release of expensive resources.

```swift
import os

/// Manages a resource with automatic lifecycle logging.
///
/// Logs acquisition, release, and elapsed time the resource was held.
/// Use for database connections, file handles, hardware access, etc.
///
/// ```swift
/// let result = try await ResourceScope.open("database", logger: logger) {
///     let db = try DatabaseConnection(path: dbPath)
///     defer { db.close() }
///     return try db.query(sql)
/// }
/// ```
public enum ResourceScope {
    public static func open<T>(
        _ name: String,
        logger: Logger,
        _ operation: () async throws -> T
    ) async throws -> T {
        logger.info("Acquiring resource: \(name, privacy: .public)")
        let start = ContinuousClock.now

        do {
            let result = try await operation()
            let elapsed = start.duration(to: .now)
            logger.info("Released resource: \(name, privacy: .public) (held \(elapsed, privacy: .public))")
            return result
        } catch {
            let elapsed = start.duration(to: .now)
            logger.error("Resource \(name, privacy: .public) failed after \(elapsed, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
```

---

### Startup Logging

Not a type — a pattern. The coding rules mandate a `logStartupContext()` call at application launch:

```swift
func logStartupContext(logger: Logger) {
    logger.notice("App launched — v\(Bundle.main.shortVersion, privacy: .public) build \(Bundle.main.buildNumber, privacy: .public)")
    logger.notice("Environment: \(AppEnvironment.current.rawValue, privacy: .public)")
    logger.notice("OS: \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
    logger.notice("Feature flags: \(FeatureFlags.current.summary, privacy: .public)")
}
```

This one stays as a coding rule rather than a type because it's a one-time call at a known location, not a repeating pattern.

---

## 4. Deliverable 2: Coding Rules (`13_LOGGING_INSTRUMENTATION.md`)

The coding rules document shifts from "here are 7 places to add logging" to "use these types — raw I/O is banned."

### Core Rule: No Raw I/O in Application Code

| Banned Pattern | Required Alternative | Why |
|---------------|---------------------|-----|
| `URLSession.shared.data(from:)` | `InstrumentedClient.data(from:)` | Network requests must be logged |
| `URLSession.shared.data(for:)` | `InstrumentedClient.data(for:)` | Same |
| `URLSession.shared.download(from:)` | `InstrumentedClient.download(from:)` | Downloads must be logged |
| Multi-step array transforms | `Pipeline` with named stages | Data loss between stages must be visible |
| Direct state mutation of app-level enums | `@Logged` property wrapper | State transitions must be traceable |
| Bare `do/catch` with silent recovery | `withObservability` or explicit `logger.error()` in catch | Errors must not be swallowed |
| `try?` without logging | `withObservability` (non-throwing variant) | Silent failures must be visible |

### Suppression

When raw I/O is genuinely needed (e.g., a performance-critical inner loop where logging overhead matters, or a low-level utility that the instrumented types themselves use internally):

```swift
// observability-bypass: Hot loop reads 10k small files; logging per-file adds 300ms
let data = try Data(contentsOf: fileURL)
```

The `// observability-bypass:` comment suppresses the auditor and documents the reason.

### OSLog Best Practices

(Same log-level table and privacy annotation rules from v1 proposal — these don't change with the architectural shift.)

| Level | Use When |
|-------|----------|
| `.fault` | Programmer error, impossible state |
| `.error` | Operation failed, user-visible impact |
| `.warning` | Degraded but functional |
| `.notice` | Significant events (state transitions, startup) |
| `.info` | Routine operations (I/O boundaries, pipeline stages) |
| `.debug` | Active investigation detail |

**Privacy annotations are mandatory** on every interpolated value:

```swift
// ✅ Every interpolation annotated
logger.info("Loaded \(items.count, privacy: .public) for \(userId, privacy: .private)")

// ❌ Missing annotation (defaults to .private but intent unclear)
logger.info("Loaded \(items.count) for \(userId)")
```

### Applicability

- **Applications** (`projectType: "application"`): All rules enforced
- **Libraries** (`projectType: "library"`): Exempt — libraries should accept a `Logger` parameter but not force instrumentation on consumers
- **Test code**: Exempt — test files are excluded from auditor scanning

---

## 5. Deliverable 3: CLAUDE.md Additions

```markdown
## Logging & Observability (Consumer-Facing Apps)

Code without logging is code you cannot debug. When writing or modifying
application code, use the structural observability primitives:

- **Network I/O:** Use `InstrumentedClient`, never raw `URLSession`
- **Data pipelines:** Use `Pipeline` with named stages
- **State changes:** Use `@Logged` property wrapper on app-level state enums
- **Other async ops:** Wrap with `withObservability("name", logger:) { ... }`
- **Resource lifecycle:** Use `ResourceScope.open("name", logger:) { ... }`
- **App launch:** Call `logStartupContext(logger:)` in app entry point

Never write bare `do/catch` with silent recovery — either use `withObservability`
(which logs errors automatically) or add explicit `logger.error()` in the catch block.

See `00_CORE_RULES/13_LOGGING_INSTRUMENTATION.md` for full reference.
```

---

## 6. Deliverable 4: LoggingAuditor v2 — Bypass Detection

### Paradigm Shift

v1 tried to detect **missing logging** (hard, heuristic, noisy).
v2 detects **bypass of instrumented types** (simple, deterministic, reliable).

### Rules

#### Existing Rules (unchanged)

| Rule ID | Severity | What It Catches |
|---------|----------|-----------------|
| `logging.print-statement` | error | Bare `print()`/`debugPrint()` |
| `logging.silent-try` | warning | `try?` without adjacent logging |
| `logging.no-os-logger-import` | warning | File has print/NSLog but no `import os` |

#### New Rules

| Rule ID | Severity | What It Catches | AST Pattern |
|---------|----------|-----------------|-------------|
| `logging.raw-urlsession` | warning | Direct `URLSession` data/download calls | `MemberAccessExprSyntax` → `URLSession` + `.data(` / `.download(` / `.upload(` |
| `logging.raw-file-io` | warning | Direct file read/write without instrumentation | `Data(contentsOf:`, `String(contentsOfFile:`, `FileManager` `.contents(atPath:`, `.createFile(` |
| `logging.missing-privacy` | warning | Logger call with interpolation but no `privacy:` | Logger method call + `StringLiteralExprSyntax` segments without `privacy:` |
| `logging.bare-logger-init` | info | `Logger()` without subsystem/category | `Logger(` with zero arguments |

#### Why Bypass Detection is More Reliable

| Property | v1 (missing logging) | v2 (bypass detection) |
|----------|---------------------|----------------------|
| False positives | High — utility async functions flagged | Near zero — raw URLSession is raw URLSession |
| False negatives | High — non-standard I/O missed | Low — finite set of raw APIs to detect |
| Signal clarity | "This function might need logging" | "This function is using the uninstrumented path" |
| Suggested fix | "Add logging somewhere" | "Replace `URLSession.shared.data` with `client.data`" |
| Suppression reasoning | Vague — "this function doesn't need it" | Specific — "performance-critical inner loop" |

### Configuration

```swift
public struct LoggingAuditorConfig: Sendable, Equatable {
    // Existing fields (unchanged)
    public let projectType: String
    public let silentTryKeyword: String
    public let allowedSilentTryFunctions: [String]
    public let customLoggerNames: [String]

    // New: bypass detection
    
    /// Enable detection of raw URLSession usage.
    public let detectRawURLSession: Bool
    
    /// Enable detection of raw file I/O.
    public let detectRawFileIO: Bool
    
    /// Enable detection of missing privacy annotations.
    public let detectMissingPrivacy: Bool
    
    /// Comment keyword that suppresses bypass detection rules.
    /// Default: "observability-bypass:"
    public let bypassKeyword: String
    
    /// Additional raw-I/O types to detect beyond URLSession/FileManager.
    /// Example: ["CoreDataStack.shared", "RealmDatabase"]
    public let additionalRawIOPatterns: [String]
}
```

**YAML example:**

```yaml
logging:
  projectType: application
  detectRawURLSession: true
  detectRawFileIO: true
  detectMissingPrivacy: true
  bypassKeyword: "observability-bypass:"
  additionalRawIOPatterns:
    - "CoreDataStack.shared"
    - "gRPCClient"
```

### Diagnostic Output

```swift
// logging.raw-urlsession
Diagnostic(
    severity: .warning,
    message: "Direct URLSession usage — use InstrumentedClient for automatic logging",
    filePath: fileName,
    lineNumber: line,
    ruleId: "logging.raw-urlsession",
    suggestedFix: "Replace URLSession.shared.data(from: url) with client.data(from: url)"
)

// logging.raw-file-io
Diagnostic(
    severity: .warning,
    message: "Direct file I/O — wrap with ResourceScope.open() or withObservability() for logging",
    filePath: fileName,
    lineNumber: line,
    ruleId: "logging.raw-file-io",
    suggestedFix: "Wrap in withObservability(\"readFile\", logger: logger) { try Data(contentsOf: url) }"
)

// logging.missing-privacy
Diagnostic(
    severity: .warning,
    message: "Logger call contains interpolation without privacy annotation",
    filePath: fileName,
    lineNumber: line,
    ruleId: "logging.missing-privacy",
    suggestedFix: "Add privacy: .public or privacy: .private to each interpolated value"
)
```

---

## 7. MCP Schema

```json
{
  "tool": "quality-gate",
  "checker": "logging",
  "description": "Audit Swift source for logging hygiene and observability bypass",
  "configuration": {
    "projectType": "application",
    "detectRawURLSession": true,
    "detectRawFileIO": true,
    "detectMissingPrivacy": true,
    "bypassKeyword": "observability-bypass:",
    "additionalRawIOPatterns": ["CoreDataStack.shared"]
  },
  "output": {
    "rules": [
      {"id": "logging.print-statement", "severity": "error", "category": "hygiene"},
      {"id": "logging.silent-try", "severity": "warning", "category": "hygiene"},
      {"id": "logging.no-os-logger-import", "severity": "warning", "category": "hygiene"},
      {"id": "logging.raw-urlsession", "severity": "warning", "category": "bypass"},
      {"id": "logging.raw-file-io", "severity": "warning", "category": "bypass"},
      {"id": "logging.missing-privacy", "severity": "warning", "category": "privacy"},
      {"id": "logging.bare-logger-init", "severity": "info", "category": "hygiene"}
    ]
  }
}
```

---

## 8. Constraints & Compliance

| Constraint | How This Complies |
|------------|-------------------|
| **Concurrency** | `InstrumentedClient` is an actor; `Pipeline` and `@Logged` are value types; all configs are Sendable |
| **Safety** | No force unwraps; all primitives guard inputs; errors are always rethrown (never swallowed) |
| **Fail-silent principle** | `withObservability` logs errors before rethrowing — callers always know something failed |
| **Library exemption** | All auditor rules respect `projectType: "library"` gate |
| **Suppression** | `// observability-bypass:` comments suppress bypass rules with audit trail |
| **Backward compat** | All new config fields default to current behavior; existing `.quality-gate.yml` files work unchanged |
| **Warning fatigue** | Bypass rules are warnings, not errors. Per ADR-012: advisory checkers must earn their keep |
| **Privacy** | `@Logged` uses `.public` for state enum descriptions (non-sensitive); `InstrumentedClient` uses `.public` for hosts/status codes, `.private` would be available for custom wrappers |

---

## 9. Dependencies

**Instrumentation Primitives Package:**
- `import os` (Apple platforms, system framework)
- `import Foundation` (`URLSession`, `URLRequest`, `Bundle`, `ContinuousClock`)
- No external dependencies

**LoggingAuditor v2:**
- `QualityGateCore` — existing dependency
- `SwiftSyntax` / `SwiftParser` — existing dependency
- No new external dependencies

**Cross-deliverable:**
- Auditor references coding rules in suggested fix messages
- CLAUDE.md references coding rules by path
- Coding rules reference the primitives package/patterns
- Coding rules (Deliverable 2) can ship independently of the primitives package (Deliverable 1)

---

## 10. Test Strategy

### Instrumentation Primitives

| Primitive | Test Categories |
|-----------|----------------|
| `InstrumentedClient` | Golden path (200 response), error path (timeout), redirect, large payload timing accuracy |
| `Pipeline` | 2-stage, 3-stage, stage that drops items, stage that throws, empty input |
| `@Logged` | Init logging, mutation logging, no-op mutation (same value), rapid mutations |
| `withObservability` | Success path with timing, error path with logging, nil-return variant |
| `ResourceScope` | Normal acquire/release, error during operation, nested scopes |

**Testing approach for log output:** Use `OSLogStore` API (macOS 12+) to query log entries programmatically in tests, or inject a mock `Logger`-compatible protocol for unit testing without OS log infrastructure.

**Reference Truth:** Behavior is defined by this proposal's specifications. Log message format and timing accuracy are the testable outputs.

### LoggingAuditor v2

#### Rule: `logging.raw-urlsession`

| Test | Input | Expected |
|------|-------|----------|
| Golden path: uses InstrumentedClient | `let (data, _) = try await client.data(from: url)` | No diagnostic |
| Violation: raw URLSession.shared.data | `let (data, _) = try await URLSession.shared.data(from: url)` | 1 warning |
| Violation: raw session variable | `let session = URLSession.shared; try await session.data(from: url)` | 1 warning |
| Exempt: suppression comment | `// observability-bypass: internal helper\nURLSession.shared.data(...)` | No diagnostic, 1 override |
| Exempt: library project type | Any URLSession usage in `projectType: "library"` | Skipped |
| Exempt: inside InstrumentedClient itself | URLSession usage inside the primitives package | Skipped (test file or excluded pattern) |

#### Rule: `logging.raw-file-io`

| Test | Input | Expected |
|------|-------|----------|
| Violation: Data(contentsOf:) | `let data = try Data(contentsOf: fileURL)` | 1 warning |
| Violation: String(contentsOfFile:) | `let text = try String(contentsOfFile: path)` | 1 warning |
| Violation: FileManager.contents | `FileManager.default.contents(atPath: path)` | 1 warning |
| Exempt: wrapped in withObservability | Inside a `withObservability` block (adjacency check) | No diagnostic |
| Exempt: suppression comment | `// observability-bypass: reason` | No diagnostic, 1 override |

#### Rule: `logging.missing-privacy`

| Test | Input | Expected |
|------|-------|----------|
| Golden path: privacy present | `logger.info("Count: \(n, privacy: .public)")` | No diagnostic |
| Violation: missing annotation | `logger.info("Count: \(n)")` | 1 warning |
| Exempt: no interpolation | `logger.info("Started")` | No diagnostic |
| Mixed: some annotated, some not | `logger.info("\(a) and \(b, privacy: .public)")` | 1 warning (for `a`) |

---

## 11. Architecture Decision Review

**ADR Check:**
- [x] Reviewed `06_ARCHITECTURE_DECISIONS.md`
- [ ] Supersedes existing ADR? No
- [ ] Amends existing ADR? No
- [x] New ADR required? Yes

**New ADR Draft:**

```yaml
id: ADR-013
date: 2026-04-30
status: proposed
category: architecture
title: Structural observability via instrumented types, not logging coverage linting
context: |
  AI-generated code passes quality checks but has zero runtime observability.
  An initial proposal tried to enforce instrumentation via AST-based detection
  of "missing logging" in async functions and catch blocks. Adversarial review
  showed this is fundamentally unreliable — a syntax checker cannot enforce a
  design pattern. Four of seven proposed rules were acknowledged as
  unenforceable by the linter.
decision: |
  Enforce observability structurally: provide typed primitives (InstrumentedClient,
  Pipeline, @Logged, withObservability, ResourceScope) that make logging automatic.
  Ban raw I/O APIs (URLSession, FileManager) in application code. The auditor's role
  shifts from "detect missing logging" to "detect bypass of instrumented types" —
  a dramatically simpler, more reliable detection surface.
rationale:
  - "Structural enforcement: if logging is in the type, it cannot be forgotten"
  - "Bypass detection has near-zero false positives (raw URLSession IS raw URLSession)"
  - "Auditor rules are simple substring/AST matches, not heuristic analysis"
  - "Follows the quality-gate philosophy: machine-enforceable checks in the gate,
     judgment-requiring guidance in the rules"
consequences: |
  + Observable code is the default — you'd have to actively bypass it
  + Debugging sessions start with structured timing data, not speculation
  + Auditor false positive rate drops from estimated 15-20% to near zero
  - Requires a new primitives package or reference implementations
  - Teams must adopt the instrumented types (incremental via warning severity)
  - InstrumentedClient wraps URLSession — teams with custom networking may need adapters
alternatives_rejected:
  - "AST-based missing-logging detection: Adversarial review showed false positive
     rate unacceptable for 4 of 7 rules — design patterns aren't syntax patterns"
  - "Behavioral guidance only (CLAUDE.md): Documentation the AI might ignore;
     no enforcement mechanism for human developers"
  - "Runtime instrumentation (swizzling, os_signpost): Invasive, fragile across
     OS versions, impossible to enforce at build time"
affected_files:
  - 00_CORE_RULES/13_LOGGING_INSTRUMENTATION.md
  - CLAUDE.md
  - quality-gate-swift/Sources/LoggingAuditor/LoggingVisitor.swift
  - quality-gate-swift/Sources/QualityGateCore/Configuration.swift
  - New: swift-observability package (or reference implementations in coding rules)
supersedes: null
amends: null
superseded_by: null
```

---

## 12. Adversarial Review

**Strongest case for a different approach:**

The primitives add a layer of abstraction over standard Apple APIs. A team that already uses Alamofire, Moya, or a custom networking stack doesn't want `InstrumentedClient` wrapping `URLSession` — they want their existing stack instrumented. The same applies to Core Data, Realm, or gRPC — each has its own I/O patterns that `InstrumentedClient` doesn't cover. The proposal is really "instrument URLSession and FileManager" dressed up as "structural observability."

**Response:** This is valid for networking stacks, but the principle scales: the auditor's `additionalRawIOPatterns` config lets teams add their own bypass-detection patterns (`CoreDataStack.shared`, `gRPCClient`). The primitives aren't the only instrumented types — they're the *reference implementations* that demonstrate the pattern. A team using Alamofire should either instrument Alamofire's session (which many already do via `EventMonitor`) or add `Alamofire.request` to their raw-I/O detection list. The coding rules should be clear that "use InstrumentedClient" means "use an instrumented I/O boundary," not specifically this one class.

**Where this design is most likely wrong:**

The `@Logged` property wrapper requires the value type to conform to `CustomStringConvertible` and `Equatable`. State enums naturally conform, but complex state objects might not have meaningful string representations. More importantly, `@Logged` works for simple properties but not for state managed by SwiftUI's `@Observable` macro or Combine publishers — the two most common state management patterns in modern iOS apps. A `@Logged` wrapper that doesn't compose with `@Observable` covers a narrow use case.

**What an experienced critic would say:**

"You've solved the easy problem (network I/O) and punted on the hard ones (state management in SwiftUI, data pipelines that aren't array transforms, catch blocks in deeply nested call stacks). `InstrumentedClient` is useful but it's ~30% of the observability surface in a real app. The other 70% is still behavioral guidance."

This is the strongest objection. The response: 30% structural enforcement is still infinitely better than 0%. The `withObservability` wrapper is the escape hatch — anything that doesn't fit a purpose-built primitive gets wrapped in `withObservability("name", logger:) { ... }`, which is detectable by the auditor (async functions with `await` but no `withObservability` or known-instrumented call) at moderate reliability. We're not claiming 100% enforcement — we're claiming that the most common debugging scenario (slow network requests, silent errors, lost data in pipelines) is structurally solved, and the rest is progressively better than the status quo.

---

## 13. Resolved Questions

1. ~~**Package vs. reference implementations?**~~ **RESOLVED: Standalone SPM package.** This will be used across every consumer-facing project (narbis, iConquer, Ignite, future projects). A package is the right investment — single source of truth, version-bumped updates, zero drift between consumers.

2. ~~**`@Logged` + SwiftUI `@Observable`?**~~ **RESOLVED: Accept the limitation.** `@Logged` works for non-SwiftUI state (CLI tools, server code, coordinators, app-level enums). For SwiftUI `@Observable` state, use `withObservability` to wrap state-changing operations. No custom macro needed.

3. **Scope of `raw-file-io` rule?** Flag `Data(contentsOf:)` universally — the auditor can't statically determine whether a URL is file or network, and both should be instrumented in application code. The `// observability-bypass:` suppression handles legitimate exceptions.

4. **Severity escalation path?** Defer to the SeverityOverrideSystem proposal. If that ships first, bypass rules automatically gain config-level severity promotion. If not, warnings are the right default for v1.

5. ~~**Implementation order?**~~ **RESOLVED:**
   - Phase 1: Coding rules document + CLAUDE.md (immediate behavioral change, zero code)
   - Phase 2: Instrumentation primitives SPM package (`swift-observability`)
   - Phase 3: LoggingAuditor v2 bypass rules (enforcement)

---

## 14. Documentation Strategy

**Documentation Type:** Narrative Article Required

**Complexity Threshold Check:**
- Combines 3+ APIs? Yes (5 primitives + auditor rules + configuration)
- Explanation requires 50+ lines? Yes
- Theory/background context needed? Yes (why structural > behavioral enforcement)

**Article Names:**
- `LoggingInstrumentationGuide.md` — How to use the primitives (for the primitives package)
- `LoggingAuditorBypassGuide.md` — How bypass detection works (extends existing auditor docs)

---

## Proposal Review Checklist

### Architecture
- [x] Module placement follows existing project structure
- [x] API design follows naming conventions (actors for mutable state, structs for config)
- [x] Concurrency model is Swift 6 compliant (`InstrumentedClient` is actor, all others are Sendable)
- [x] No forbidden patterns in proposed implementation
- [x] Primitives use `os.Logger` exclusively (no print, no NSLog)

### MCP Readiness
- [x] MCP JSON schema defined
- [x] All parameter types mapped
- [x] Rule categories enumerated

### Testing & Dependencies
- [x] Test strategy covers all primitives and all new auditor rules
- [x] Reference truth identified (proposal specifications)
- [x] Dependencies acceptable (only `os` + `Foundation` for primitives)
- [x] Open questions documented

### Adversarial Review
- [x] Counter-design articulated (custom networking stacks, `@Observable` incompatibility)
- [x] Failure mode named (`@Logged` doesn't compose with SwiftUI state management)
- [x] Critic's objection captured ("solves 30% structurally, punts on 70%")
- [x] Response provided (30% structural > 0% structural; `withObservability` covers the rest progressively)
