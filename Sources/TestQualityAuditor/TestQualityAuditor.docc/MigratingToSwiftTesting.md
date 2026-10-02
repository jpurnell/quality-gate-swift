# Migrating to Swift Testing with --fix

Convert the files `xctest-import` flags, and know what is left for you afterwards.

## Overview

`xctest-import` reports one finding per test file that imports XCTest. The repair is
mechanical in bulk and judgement at the edges, and `--fix` does the mechanical part:

```
quality-gate --check test-quality --fix
swift build --build-tests
swift test
```

The conversion works on the syntax tree, not the text, so a string literal is never
rewritten, even one whose contents are an XCTest file (a fixture). Before writing a file it
checks three things, and refuses the file if any of them fails:

- **No test is orphaned.** XCTest finds tests by name and Swift Testing by attribute. A
  `func test…()` that does not come out as an `@Test` function does not fail; it stops
  running. The count before is taken independently of the conversion: every parameterless
  `func test…` in any class or extension in the file. So a test the conversion did not
  reach makes the counts disagree.
- **The result parses.**
- **The result does not contain the next finding.** An exact `XCTAssertEqual` on `Double`
  would become `#expect(a == b)`, which `exact-double-equality` rejects. The conversion runs
  the gate's own detector over its output and restates each such comparison as
  `a.isEqual(to: b)`. That is the exact claim `XCTAssertEqual` made, now named. It is never
  loosened to a tolerance.

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
| `XCTAssertTrue`/`False`/`Nil`/`NotNil` | `#expect(x)`, `#expect(!x)`, `== nil`, `!= nil` |
| `XCTUnwrap(x)` | `#require(x)` |
| `XCTFail(msg)`, `return XCTFail(msg)` | `Issue.record(msg)`, `Issue.record(msg); return` |
| `XCTAssertThrowsError(e) { error in … }` | `if let error = #expect(throws: (any Error).self, performing: { e }) { … }`, with `$0` renamed |
| `XCTAssertNoThrow(e)` | `#expect(throws: Never.self) { e }` |
| `file: StaticString = #filePath, line: UInt = #line` | `sourceLocation: SourceLocation = #_sourceLocation` |
| a message that is not a string literal | `"\(message)"` |

## What is left for you

These come back as unfixed findings at their lines, and stay in the file as written. That
means the file will not compile until each is decided. That is deliberate: every one has
more than one correct form.

- **`XCTSkip`.** Either the test does not apply here, which is an `.enabled(if:)` trait, or a
  helper met a value it did not expect, which is a failure. In the migration that motivated
  this fix, 32 of 39 skips were the second kind, written as the first.
- **A nil check on a value declared non-optional.** It can never fail. XCTest took `Any?`,
  which is why it compiled. Written as `#expect(x != nil)` it is a compiler warning, and on
  an existential it crashed swift-frontend 6.4.
- **Expectations, `wait(for:)`, `measure`, `XCTContext`, `addTeardownBlock`,
  `XCTExpectFailure`, `continueAfterFailure`, `executionTimeAllowance`,** and a
  `tearDown` that is async or throws.

Two things the conversion cannot see, and the compiler will name:

- **A throwing call inside `XCTUnwrap` from another file.** `try XCTUnwrap(f())` covered a
  throwing `f`; `#require` needs its own: `try #require(try f())`. The conversion adds it
  where this file declares `f` as throwing.
- **`XCTUnwrap` of a value that is not optional.** XCTest took `T?`, so unwrapping a
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
