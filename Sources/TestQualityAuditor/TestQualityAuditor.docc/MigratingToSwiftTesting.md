# Migrating to Swift Testing with --fix

Convert the files `xctest-import` flags, and know what is left for you afterwards.

## Overview

`xctest-import` reports one finding per test file that imports XCTest. The repair is
mechanical in bulk and judgement at the edges, and `--fix` does the mechanical part:

```
quality-gate --check test-quality --fix --dry-run
quality-gate --check test-quality --fix
swift build --build-tests
swift test
```

**A file is converted whole or not at all.** The conversion works on the syntax tree, not the
text, so a string literal is never rewritten, even one whose contents are an XCTest file (a
fixture). Before writing a file it checks five things, and leaves the file exactly as it was
if any of them fails:

- **Nothing in it needs a decision.** See "What stops a file" below. Each of those has more
  than one correct Swift Testing form, and which one depends on what the test meant.
- **No test is orphaned.** XCTest finds tests by name and Swift Testing by attribute. A
  `func test…()` that does not come out as an `@Test` function does not fail; it stops
  running. The count before is taken independently of the conversion: every parameterless
  `func test…` in any class or extension in the file. So a test the conversion did not
  reach makes the counts disagree.
- **The result parses.**
- **Exact float comparisons are named.** An exact `XCTAssertEqual` on `Double` would become
  `#expect(a == b)`, which `exact-double-equality` rejects. The conversion runs the gate's own
  detector over its output and restates each such comparison as `a.isEqual(to: b)`. That is
  the exact claim `XCTAssertEqual` made, now named. It is never loosened to a tolerance.
- **The gate has nothing new to say about the result.** Every per-file `test-quality` rule
  is run over the text about to be written. If a rule would report something it did not
  report on the original, the file is not written and that finding is the reason given. A
  finding the original already had (a `try!`, an unseeded `.random`) is not the conversion's
  and does not stop it.

The last check is what makes the others worth having. The first version of this fix wrote
`#expect(x != nil)` for every `XCTAssertNotNil(x)`, and `weak-assertion` reports exactly that:
on one 572-test suite, the run that cleared 50 `xctest-import` errors created 84 warnings.

### What the run prints

For each file it rewrote, one line. For each file it left alone, the file and, under it,
every construct that stopped it, at its line:

```
[test-quality] Applying fixes...
  ✓ Tests/AppTests/ModelTests.swift — Converted to Swift Testing (17 tests), 121 lines
  ✗ Tests/AppTests/CorpusTests.swift — not changed:
      line 62: XCTSkip: only a skip that is the first statement of a test, on a condition …
  ✗ Tests/AppTests/LegacyTests.swift — not changed:
      line 7: @available(*, deprecated) on LegacyTests: Swift Testing refuses @Suite on a …
  ℹ  7 other findings are not auto-fixable; see the report below
```

`--fix --dry-run` runs the same conversion and the same checks and writes nothing. It prints
`would change` and `would not change` in place of the marks, so the preview cannot promise a
file the fix would then decline.

## What converts

| XCTest | Swift Testing |
|---|---|
| `final class T: XCTestCase` | `@Suite struct T`, or `@Suite final class T` when it has `setUp`/`tearDown` or a stored `var` |
| `setUp`, `setUpWithError`, async `setUp` | `init()`, keeping `async` and `throws` |
| `tearDown`, `tearDownWithError` | `deinit`, if nothing in it throws |
| `func testFooBar()`, in the class or an extension of it | `@Test func fooBar()`; the prefix stays when the lowered name is a keyword or already taken |
| `XCTAssertEqual(a, b, msg)` and the other comparisons | `#expect(a == b, msg)`, with `try`/`await` moved to the front |
| `…, accuracy: e` | `#expect(abs(a - b) <= e)` |
| `XCTAssertEqual([x, y], [1, 2])` | `#expect([x, y].elementsEqual([1, 2]))`: two untyped array literals are ambiguous to `#expect`'s operator overloads |
| `XCTAssertTrue`/`False`/`Nil` | `#expect(x)`, `#expect(!x)`, `#expect(x == nil)` |
| `XCTAssertNotNil(x)` | `_ = try #require(x)`, and the test gains `throws` |
| `XCTUnwrap(x)` | `#require(x)` |
| `XCTFail(msg)`, `return XCTFail(msg)` | `Issue.record(msg)`, `Issue.record(msg); return` |
| `XCTAssertThrowsError(e) { error in … }`, the closure trailing or passed as the last argument | `if let error = #expect(throws: (any Error).self, performing: { e }) { … }`, with `$0` renamed |
| `XCTAssertThrowsError(e)` | `#expect(throws: (any Error).self) { e }` |
| `XCTAssertNoThrow(e)` | `#expect(throws: Never.self) { e }` |
| `do { try f(); XCTFail(msg) } catch is E { } catch { XCTFail(…) }` | `#expect(throws: E.self, msg) { try f() }` |
| `try XCTSkipUnless(c, why)`, `try XCTSkipIf(c, why)`, `guard c else { throw XCTSkip(why) }` as a test's first statement | `@Test(.enabled(if: c, why))` |
| `file: StaticString = #filePath, line: UInt = #line` | `sourceLocation: SourceLocation = #_sourceLocation` |
| a message that is not a string literal | `"\(message)"`, or `Comment(rawValue: message)` when it spans lines |

### Where a line is added before the assertion

`XCTAssert*` took its arguments as the autoclosures of a function. `#expect` and `#require`
are macros, and some things that compiled inside the function do not compile inside the
macro, or compile into something the gate reports. Each of these is bound to a `let` on the
line before the assertion. The name comes from the expression (`q.next()` is `next`, a bare `x` is `xValue`), is
unique within the test, and avoids every name the file already uses.

| XCTest | Swift Testing | Why |
|---|---|---|
| `XCTAssertTrue(q.next())`, `q` a `var` | `let next = q.next()` then `#expect(next)` | A mutating call inside `#expect` is "cannot use mutating member on immutable value". Calls to its left are bound too, so they still run first |
| `XCTUnwrap(rows[XCTUnwrap(key)])` | `let keyValue = try #require(key)` then `#require(rows[keyValue])` | `#require` inside `#require` is "recursive expansion of macro" |
| `XCTAssertEqual(try XCTUnwrap(x).count, 3)` | `let xValue = try #require(x)` then `#expect(xValue.count == 3)` | The unwrap is one statement and the claim is another |
| `XCTAssertTrue((name ?? "").isEmpty)` | `let nameValue = try #require(name)` then `#expect(nameValue.isEmpty)` | `coalesced-assertion`: with the fallback, a missing value is asserted on as though it were an empty one |
| `XCTUnwrap(cells.compactMap { sheet.cell(at: $0)?.formula }.first)` | `let compactMapResult = cells.compactMap { … }` then `#require(compactMapResult.first)` | A condition that is a property access is expanded into a separate read of the property. The macro sees the `?` in the closure and writes that read as optional chaining |

Two of these rows are stricter than what they replace, on purpose. `XCTAssertNotNil(x)`
carried on after a failure and `try #require(x)` stops the test. `x ?? ""` let a missing
value through and `try #require(x)` fails on it. Both are the forms this gate's own rules ask
for, and neither can pass a test the original would have failed.

A value is only moved ahead of its statement when the statement always evaluated it. Right of
`&&`, in the second clause of an `if`, in a loop condition or in a closure it did not, and
there the file is left alone.

## What stops a file

A file holding any of these is not converted. Each is reported at its line, with the reason,
and the file is left exactly as it was: still XCTest, still compiling, still running. It
used to be converted around them, which left a file that no longer imported XCTest and did
not build.

- **`XCTSkip` that is not a test's opening condition.** Either the test does not apply here,
  which is an `.enabled(if:)` trait, or a helper met a value it did not expect, which is a
  failure. In the migration that motivated this fix, 32 of 39 skips were the second kind,
  written as the first. A leading skip whose condition reads the suite's own stored state is
  also left: a trait is evaluated before the suite exists.
- **A suite marked `@available`.** Swift Testing refuses `@Suite` on a declaration carrying
  `@available`, deprecated or platform-limited, and `@Test` on anything inside one. A suite
  marked `@available(*, deprecated)` so it can call deprecated API without a warning has to
  make those calls through a deprecated helper instead.
- **A nil check on a value that is not optional**: a local declared with a non-optional
  type, or the error `XCTAssertThrowsError` hands its closure. It can never fail. XCTest
  took `Any?`, which is why it compiled.
- **`XCTAssertNotNil` in a closure or a helper.** As `try #require` it needs the closure or
  the helper to throw, and whatever calls them to `try`.
- **An unwrap that cannot be bound ahead of its statement** and cannot stay where it is: an
  `XCTUnwrap` in a closure inside another `XCTUnwrap`.
- **`return` inside an `XCTAssertThrowsError` closure** when more of the test follows. The
  closure's statements become the body of an `if`, where `return` would leave the test.
- **Expectations, `wait(for:)`, `measure`, `XCTContext`, `addTeardownBlock`,
  `XCTExpectFailure`, `continueAfterFailure`, `executionTimeAllowance`,** and a
  `tearDown` that is async or throws.
- **Anything the gate would report on the converted file and did not report on the
  original.** A test whose only checks were `XCTFail` (`missing-assertion`); a
  `guard let … else { return }` in a test (`unasserted-optional-unwrap`). Both rules read
  `@Test` functions, so the finding only exists once the file is converted. The reason quotes
  the rule and the converted line.

Three things the conversion cannot see, and the compiler will name:

- **A throwing call inside `XCTUnwrap` from another file.** `try XCTUnwrap(f())` covered a
  throwing `f`; `#require` needs its own: `try #require(try f())`. The conversion adds it
  where this file declares `f` as throwing.
- **`XCTUnwrap` or `XCTAssertNotNil` of a value that is not optional**, where its type is
  not written in the file. XCTest took `T?`, so unwrapping a
  non-optional compiled and could never fail. Typically an API stopped returning an optional
  and its tests were not updated. `#require` on it is a compiler warning, "redundant because
  … never equals nil". The fix is to drop the `try #require(…)`. In SwiftExcelCore, seven
  `XCTUnwrap(cells.matrix(in:))` sites turned out to be this.
- **An optional compared exactly as a float,** where the optional is neither an optional
  chain nor a call to a function this file declares as returning one. The forms it can see
  become `a?.isEqual(to: b) == true`.

## Running the tests afterwards

A converted suite can compile cleanly and still fail or crash, for reasons no syntax check
can see. **XCTest ran each test on the main thread, with an 8 MiB stack, one at a time.
Swift Testing runs tests in parallel on the cooperative pool, whose threads have 512 KiB.**

- Recursion that fitted the main thread's stack can now overflow it. That shows up as a
  `SIGBUS` in the test process, not as a failing test.
- State shared between tests, which serial runs never exposed, can now race.

The migration that motivated this fix lost eleven tests to the first of these: an
expression evaluator's depth bound had been measured on the main thread. Those tests now
run their deep work on a thread created with an 8 MiB `stackSize`. Callers of the library
in Swift concurrency still have the small stack, which is a real finding about the library
that the old test runner had been hiding.
