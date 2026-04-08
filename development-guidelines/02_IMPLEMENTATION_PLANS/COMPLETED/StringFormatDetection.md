# SafetyAuditor: C-Style Format String Detection

**Status:** DRAFT — ready for implementation
**Date:** 2026-04-07
**Driver:** `String(format:)` is on the project's Forbidden Patterns list in
`development-guidelines/00_CORE_RULES/01_CODING_RULES.md` but is not
mechanically detected. Recurring source of SIGSEGV crashes in downstream
projects (most recently a `%s` + Swift String crash in BioFeedbackKit's
FrequencyDomain validation playground on 2026-04-07). The rule exists; the
enforcement does not. This plan adds the enforcement.
**Author of plan:** transcribed from a narbis design session — another instance
will implement.

---

## 1. Objective

Add C-style format string detection to the existing `SafetyAuditor` module so
that `swift run quality-gate --check safety` (and the CLI's default run) flag
any call to `String(format:)`, `NSString(format:)`, or related format-string
APIs that bridge to the unsafe C printf ABI.

The detection must:

- Catch the patterns the human eye misses, including `String(format: "%s", swiftString)` which compiles cleanly and crashes at runtime with no warning.
- Produce a clear, actionable diagnostic that points the user at the relevant section of the coding rules and suggests a safer alternative.
- Honor the existing line-level exemption mechanism (`// SAFETY:` comments and any patterns configured in `safetyExemptions`).
- Run in the same pass as the rest of `SafetyAuditor` — no new module, no new CLI command, no extra walk over the source tree.

This is a small addition to an existing checker, not a new checker.

---

## 2. Why this lives in `SafetyAuditor` and not a new module

`SafetyAuditor.swift` already:
- Walks Swift sources via `SwiftSyntax` / `SwiftParser`
- Overrides `SyntaxVisitor` callbacks for force unwrap, force cast, force try, and `FunctionCallExprSyntax` (for `fatalError()`, `precondition()`, etc.)
- Emits `Diagnostic` values with `severity`, `message`, `file`, `line`, `column`, `ruleId`, `suggestedFix`
- Honors line-level exemptions through `isExempted(line:)` against `safetyExemptions` patterns
- Is registered as the `safety` checker in `QualityGateCore`

A C-style format string check is **the same shape of work** — it's another forbidden pattern that requires walking function calls and checking the callee + argument labels. Adding it as a sibling check in `SafetyVisitor` reuses everything: the file walk, the exemption logic, the diagnostic plumbing, the CLI integration, the SARIF/JSON output formats, and the existing test infrastructure.

A separate module would duplicate all of that for one new rule. Don't do it.

---

## 3. Detection algorithm

### 3.1 Patterns to detect

| Pattern | Notes | ruleId |
|---|---|---|
| `String(format: ...)` | The most common offender. Bridges to NSString's `+stringWithFormat:` which uses C printf. | `c-style-format-string` |
| `String(format: ..., locale: ...)` | Locale-explicit variant. Same underlying ABI, same risk. | `c-style-format-string` |
| `String(format: ..., locale: ..., arguments: ...)` | varargs variant. Same risk. | `c-style-format-string` |
| `NSString(format: ...)` | Direct NSString constructor. Same ABI. | `c-style-format-string` |
| `NSString.localizedStringWithFormat(...)` | Same risk; less common but still C-ABI underneath. | `c-style-format-string` |

All five patterns share the same `ruleId` because they share the same underlying problem and the same fix.

### 3.2 SwiftSyntax detection

Each of the patterns above is a `FunctionCallExprSyntax` whose `calledExpression` resolves to a known type or member. The existing `visit(_ node: FunctionCallExprSyntax)` override in `SafetyVisitor` already handles function call walking — extend it.

```swift
// Inside SafetyVisitor.visit(_ node: FunctionCallExprSyntax) → SyntaxVisitorContinueKind

// Existing logic checks calledExpression.as(DeclReferenceExprSyntax.self)
// for fatalError/precondition/etc. Add a parallel branch for format strings.

if isCStyleFormatStringCall(node) {
    let location = node.startLocation(
        converter: SourceLocationConverter(fileName: fileName, tree: node.root)
    )
    let line = location.line

    if !isExempted(line: line) {
        diagnostics.append(Diagnostic(
            severity: .error,
            message: """
                C-style format string call detected. \
                String(format:) bridges to the C printf ABI: %s expects a \
                C string pointer (not Swift String) and will crash at runtime \
                with SIGSEGV. Width specifiers like %-30s are not supported. \
                Type errors are caught only at runtime.
                """,
            file: fileName,
            line: line,
            column: location.column,
            ruleId: "c-style-format-string",
            suggestedFix: """
                Use string interpolation "\\(value)", or value.formatted(), \
                or value.formatted(.number.precision(.fractionLength(N))) \
                for decimal places, or String.padding(toLength:withPad:startingAt:) \
                for column alignment. \
                See development-guidelines/00_CORE_RULES/01_CODING_RULES.md §3.7.
                """
        ))
    }
}
```

The `isCStyleFormatStringCall(_:)` helper inspects the called expression and the arguments:

```swift
private func isCStyleFormatStringCall(_ node: FunctionCallExprSyntax) -> Bool {
    // Case 1: String(format: ...) — calledExpression is a DeclReferenceExpr "String"
    //         with first argument label "format".
    if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
       ref.baseName.text == "String",
       hasFormatArgument(node) {
        return true
    }

    // Case 2: NSString(format: ...) — same shape, baseName "NSString".
    if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
       ref.baseName.text == "NSString",
       hasFormatArgument(node) {
        return true
    }

    // Case 3: NSString.localizedStringWithFormat(...) — calledExpression
    //         is a MemberAccessExpr whose declName is "localizedStringWithFormat"
    //         and whose base is "NSString".
    if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
       member.declName.baseName.text == "localizedStringWithFormat",
       let base = member.base?.as(DeclReferenceExprSyntax.self),
       base.baseName.text == "NSString" {
        return true
    }

    return false
}

private func hasFormatArgument(_ node: FunctionCallExprSyntax) -> Bool {
    // The first labeled argument should be "format:"
    guard let first = node.arguments.first else { return false }
    return first.label?.text == "format"
}
```

### 3.3 What NOT to flag

False positives erode trust in the linter. Explicitly avoid flagging:

1. **Strings that *contain* the substring `String(format:`** without it being an actual call — e.g. inside a string literal, doc comment, or `#""# raw string. Using `SwiftSyntax` (not regex) automatically handles this because the visitor only fires on real `FunctionCallExprSyntax` nodes.
2. **Custom types named `String` or `NSString`** in nested or shadowed scopes. The diagnostic will be correct for >99% of real codebases; if a project genuinely shadows `String`, they can add a `safetyExemptions` pattern. Document this edge case in the rule docs but don't try to resolve type identity (out of scope — would require full semantic analysis).
3. **Calls inside `// SAFETY:`-marked lines** or any pattern listed in `Configuration.safetyExemptions`. This is already handled by `isExempted(line:)` — just call it like the other detectors do.
4. **Format-style methods that don't bridge to C printf**, including:
   - `String(format: someStringInterpolationFormatStyle)` — if Swift adds a non-C-ABI overload taking a different type, the AST will look identical at the call site. Detection should still flag it because we want to enforce the rule consistently; users can exempt if they're sure the new overload is safe. (This is a hypothetical future risk; not an issue today.)
   - `Foundation.DateFormatter.string(from:)`, `NumberFormatter.string(from:)` — different APIs entirely.
   - `Date.formatted()`, `Double.formatted()`, any `FormatStyle` — these are the recommended replacements.

### 3.4 Edge cases worth a test

- `String(format: "hello")` — zero args, still a banned call.
- `String(format: "%@", someNSString)` — uses `%@` correctly but is still banned (we don't whitelist "safe" specifiers because the next change might add a `%s`).
- `String(format: "%.3f", time)` — looks innocuous, still banned.
- `let s = String(format: "%s", swiftString)` — the actual SIGSEGV pattern.
- `someString.padding(toLength: 30, ...)` — must NOT be flagged. This is the recommended alternative.
- A line ending with `// SAFETY: legacy printf debug, removing in #123` — must NOT be flagged.
- A type alias `typealias FormattedString = String` followed by `FormattedString(format: ...)` — won't be caught because the called expression's base name won't be "String". Acceptable v1 limitation; document.
- `String(format:)` inside a `///` doc comment — must NOT be flagged. (SwiftSyntax handles this — comments are trivia, not parsed as expressions.)
- `String(format:)` inside a `"""..."""` string literal — must NOT be flagged. (Handled by SwiftSyntax for the same reason.)

---

## 4. Diagnostic format

Match the existing `SafetyAuditor` diagnostic shape exactly:

```swift
Diagnostic(
    severity: .error,
    message: "C-style format string call detected. String(format:) bridges to the C printf ABI: %s expects a C string pointer (not Swift String) and will crash at runtime with SIGSEGV. Width specifiers like %-30s are not supported. Type errors are caught only at runtime.",
    file: fileName,
    line: line,
    column: location.column,
    ruleId: "c-style-format-string",
    suggestedFix: "Use string interpolation \"\\(value)\", or value.formatted(), or value.formatted(.number.precision(.fractionLength(N))) for decimal places, or String.padding(toLength:withPad:startingAt:) for column alignment. See development-guidelines/00_CORE_RULES/01_CODING_RULES.md §3.7."
)
```

**Severity is `.error`** (matching force unwrap, force cast, force try, fatalError) — not `.warning`. The pattern produces runtime crashes that the compiler doesn't catch; treating it as a warning means it gets ignored.

---

## 5. Exemption support

Use the existing `isExempted(line:)` mechanism in `SafetyVisitor`. No new exemption type, no new configuration field.

A user wanting to allow a specific call (e.g., during a migration) writes:

```swift
// SAFETY: pre-existing legacy code, scheduled for removal in PR #456
let line = String(format: "%s passed", testName)
```

This matches the existing `// SAFETY:` exemption pattern that the other forbidden-pattern detectors already honor.

For project-wide exemption (e.g., a vendored third-party file), the existing `Configuration.excludePatterns` glob list works as-is — no changes needed.

---

## 6. Test plan

All tests live in `Tests/SafetyAuditorTests/`. Add a new test file:

`Tests/SafetyAuditorTests/CStyleFormatStringDetectionTests.swift`

### 6.1 Required tests

Each test feeds a small Swift source string to `SafetyAuditor.auditSource(_:fileName:configuration:)` and asserts on the resulting `CheckResult.diagnostics`.

```swift
@Test("Detects String(format:) with single string argument")
func detectsStringFormatBasic() async throws { ... }

@Test("Detects String(format:) with multiple arguments")
func detectsStringFormatMultiArg() async throws { ... }

@Test("Detects String(format:) with locale parameter")
func detectsStringFormatWithLocale() async throws { ... }

@Test("Detects String(format:) with locale and arguments parameters")
func detectsStringFormatWithVarArgs() async throws { ... }

@Test("Detects NSString(format:) constructor")
func detectsNSStringFormat() async throws { ... }

@Test("Detects NSString.localizedStringWithFormat(_:_:)")
func detectsLocalizedStringWithFormat() async throws { ... }

@Test("Does NOT flag String(format:) inside a string literal")
func doesNotFlagInsideStringLiteral() async throws { ... }

@Test("Does NOT flag String(format:) inside a doc comment")
func doesNotFlagInsideDocComment() async throws { ... }

@Test("Does NOT flag String(format:) inside a multi-line string")
func doesNotFlagInsideMultiLineString() async throws { ... }

@Test("Does NOT flag String(format:) on a line marked // SAFETY:")
func honorsSafetyExemption() async throws { ... }

@Test("Does NOT flag String.padding(toLength:withPad:startingAt:)")
func doesNotFlagStringPadding() async throws { ... }

@Test("Does NOT flag value.formatted()")
func doesNotFlagFormattedExtension() async throws { ... }

@Test("Does NOT flag DateFormatter.string(from:)")
func doesNotFlagDateFormatter() async throws { ... }

@Test("Diagnostic has severity .error")
func diagnosticSeverityIsError() async throws { ... }

@Test("Diagnostic ruleId is c-style-format-string")
func diagnosticRuleId() async throws { ... }

@Test("Diagnostic suggestedFix points at the coding rules document")
func diagnosticSuggestedFixCitation() async throws { ... }

@Test("Multiple violations in one file produce multiple diagnostics")
func multipleViolationsProduceMultipleDiagnostics() async throws { ... }

@Test("Reports correct line and column for nested calls")
func reportsCorrectLineColumnForNestedCalls() async throws { ... }
```

### 6.2 Integration smoke test

One full-pipeline test that runs `SafetyAuditor.check(configuration:)` over a temporary directory containing both clean and dirty Swift files, and asserts that exactly the dirty files appear in the diagnostics.

### 6.3 Reference fixture from the field

Include the actual line that crashed BioFeedbackKit's playground as a regression fixture:

```swift
@Test("Regression: BioFeedbackKit playground %s + Swift String crash")
func regressionBioFeedbackPlayground() async throws {
    let source = """
        let label = "test"
        let line = String(format: "%s passed", label)
        """
    // Assert: exactly one diagnostic, ruleId == "c-style-format-string"
}
```

---

## 7. Configuration changes

**None required.**

The existing `Configuration` struct already has `safetyExemptions: [String]` and `excludePatterns: [String]` which both apply to the new check. No new fields, no new YAML keys, no migration.

If the project later wants to opt out of just the format-string check while keeping other safety checks enabled, that can be added as a follow-up via a `disabledRules: [String]` field. Don't add it now — YAGNI.

---

## 8. Documentation updates

When this ships, update:

1. **`Sources/SafetyAuditor/SafetyAuditor.swift`** — extend the doc comment at the top of the type to list `c-style-format-string` alongside the existing forbidden patterns:

   ```swift
   /// Scans Swift source files for forbidden patterns.
   ///
   /// Forbidden patterns include:
   /// - Force unwraps (`!`)
   /// - Force casts (`as!`)
   /// - Force try (`try!`)
   /// - `fatalError()`
   /// - `precondition()`
   /// - `unowned`
   /// - `assertionFailure()`
   /// - `while true`
   /// - **C-style format strings (`String(format:)`, `NSString(format:)`, etc.)** ← NEW
   ```

2. **`Sources/SafetyAuditor/SafetyAuditor.docc/`** — if there's a documentation article on safety patterns, add a section on c-style format strings with the same crash explanation and recommended alternatives.

3. **`README.md`** — if it lists checks, add the new rule.

4. **`development-guidelines/00_CORE_RULES/01_CODING_RULES.md`** in this repo — already updated upstream to include the rule in the Forbidden Patterns table. Verify this repo's local copy is in sync after implementation lands.

5. **CHANGELOG** for the next quality-gate-swift release — note the new check.

---

## 9. Estimated scope

| Item | Estimate |
|---|---|
| Implementation in `SafetyAuditor.swift` (new helper + visit branch) | ~40 lines |
| Test file `CStyleFormatStringDetectionTests.swift` | ~250 lines (18 tests) |
| Doc updates (SafetyAuditor.swift comment, README, CHANGELOG) | ~20 lines |
| **Total** | **~310 lines** |

This is a small change. The bulk is in tests (which is the right ratio for a linter rule — false positives and false negatives are the primary failure modes).

---

## 10. Future extensions (NOT this PR)

After this lands, the same `SafetyAuditor` mechanism can detect related unsafe ABIs. Track these as separate rules with separate ruleIds, not as part of this PR:

- **`withVaList(_:_:)`** — explicit C varargs construction
- **Direct `printf`, `fprintf`, `sprintf` calls** — unlikely in modern Swift but possible via C interop
- **`CFString` format functions** — `CFStringCreateWithFormat`, etc.
- **Custom `+stringWithFormat:` overloads** on user-defined types — requires nominal type analysis to detect reliably; out of scope until SwiftSyntax + semantic analysis is available

---

## 11. Approval checklist

- [ ] Approve detection scope (`String(format:)`, `NSString(format:)`, `NSString.localizedStringWithFormat`)
- [ ] Approve diagnostic message text and the citation to `01_CODING_RULES.md §3.7`
- [ ] Approve severity = `.error` (not `.warning`)
- [ ] Approve `ruleId = "c-style-format-string"`
- [ ] Approve "no new Configuration fields" (use existing exemption mechanism)
- [ ] Approve test plan (18 tests + integration smoke + regression fixture)
- [ ] Approve "extend SafetyAuditor, do not create new module"

---

## 12. Open questions

1. **Should the diagnostic message be shorter?** The proposed message is verbose. If the existing `SafetyAuditor` diagnostics are typically one sentence, match that style and move the detail into the `suggestedFix` field. Recommended: keep the rationale in `message` (because users see it first) and the fix recipe in `suggestedFix`. Implementer's call.

2. **Do we want a "first match per file" mode?** The existing checker reports every violation. For a 25-file BusinessMath cleanup PR, that's a lot of noise. Keep "every match" as the default; if noise becomes a problem, add a `--limit-per-file` CLI flag later. Out of scope for this PR.

3. **Should this PR include a `--fix` mode that auto-rewrites `String(format: "%.3f", x)` to `x.formatted(...)`?** **No.** Auto-rewriting format strings is risky because the format spec doesn't fully constrain the result type or locale behavior. Manual fix only, with the suggestedFix as guidance.

---

## 13. References

- `development-guidelines/00_CORE_RULES/01_CODING_RULES.md` §3.7 — the rule this detection enforces
- Existing `Sources/SafetyAuditor/SafetyAuditor.swift` — the file to extend
- The 2026-04-07 BioFeedbackKit crash that motivated this — exit 139 SIGSEGV inside `__CFStringAppendFormatCore`, caused by `String(format: "%s", swiftString)` in a validation playground. Documented in the narbis project's session memory at `~/.claude/projects/-Users-jpurnell-Dropbox-Computer-Development-Swift-narbis/memory/feedback_no_string_format.md`.

---

**Last Updated:** 2026-04-07
