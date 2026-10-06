# ``ExternalInputSyntax``

The gate's one external-input source model, read off a SwiftSyntax tree.

## Overview

Five security proposals each needed to know whether a value came from outside the program, and
each wrote a partial definition: request content and MCP arguments for a loop bound, the same for
an integer trap, file and network bytes for a size ceiling, a workbook cell for a regular
expression, request accessors for a redirect and for error text. `ExternalInput` in
`QualityGateCore` is their union, syntax-free and table-tested. This module is the adapter that
lets a SwiftSyntax visitor ask it about an expression: ``ExternalInputFile``.

### Source kinds

| kind | recognised by | reach | defined in |
|---|---|---|---|
| `requestContent` | `req.content`/`.query`/`.parameters`/`.headers`/`.body`/`.cookies`/`.url` on a `Request` parameter, or an untyped `req`/`request` closure parameter in a file importing Vapor or Hummingbird; a parameter of a type the file declares `Content` | network | ACountFromOutsideNeedsACeiling §3.2, ATrapIsAnOutage §3.2, AStringThatEndsALineStartsAnother §3.3, AnErrorIsNotAResponse §9 |
| `mcpArgument` | SwiftMCPServer's accessors (`getString`, `getInt`, `getIntOptional`, … — the list `MCPSchemaVisitor` checks) called with an unlabelled key; a parameter typed `[String: AnyCodable]`, `[String: Value]` (in a file importing `MCP`), or `CallTool.Parameters` | network | ACountFromOutsideNeedsACeiling §3.2, ATrapIsAnOutage §3.2 |
| `commandLine` | `CommandLine.arguments`, `ProcessInfo.processInfo.arguments`, an `@Argument`/`@Option`/`@Flag`/`@OptionGroup` property of the enclosing type | local | ACountFromOutsideNeedsACeiling §3.2, ATrapIsAnOutage §3.2 |
| `environment` | `ProcessInfo.processInfo.environment`, `getenv`, Vapor `Environment.get` | local | ACountFromOutsideNeedsACeiling §3.2, ATrapIsAnOutage §3.2 |
| `fileBytes` | `Data`/`NSData`/`String`/`NSString` `(contentsOf:)` and `(contentsOfFile:)`, `FileManager.contents(atPath:)`, `FileHandle` `readToEnd()`/`readDataToEndOfFile()`/`readData(ofLength:)`/`read(upToCount:)`/`availableData`, `readLine()` | unknown | BytesFromOutsideNeedACeiling §3.3 |
| `networkBytes` | `data`/`bytes`/`download`/`upload` `(from:)`/`(for:)` on a receiver whose text contains "session"; NIO `ByteBuffer` `readString`/`readBytes`/`readSlice`/`readInteger`/`readData(length:)`/`get…(at:)`/`readableBytesView` | network | BytesFromOutsideNeedACeiling §3.3 |
| `documentCell` | a parameter whose type names `CellValue` | unknown | APatternIsAProgram §2, ATrapIsAnOutage §3.7 |
| `decodedValue` | `decode(_:from:)` whose bytes the function did not trace (traced bytes keep their own kind) | unknown | ACountFromOutsideNeedsACeiling §3.2 |

### Propagation, within one function

- `let`/`var` with an initialiser, `if let`/`guard let`, `case let` patterns, tuple patterns and
  `for` loops bind a name to a value; a name is followed to its latest earlier binding, at most
  `ExternalInput.maximumHops` (8) times.
- Member access and subscript on an external value are external and *direct*.
- A conversion initialiser — `Int(x)`, `String(x)`, `URL(string: x)`, `Data(x)` — keeps the value
  external and direct. `decode` on an external receiver is direct.
- A method called on an external value, a string interpolation, an operator (`+`, `??`), a
  ternary's branches and a collection literal containing one are external, *not direct*.
- `try`, `await`, `?`, `!`, parentheses and `as` casts are transparent.

*Direct* means the value is the source under a name — the distinction `ATrapIsAnOutage` §3.2
draws between `let n = args.getInt("n")` and `let months = years * 12`.

### What is not tracked

- **Anything across a function boundary.** A free function's result is not traced, even from an
  external argument — which is also how an escaper such as
  `NSRegularExpression.escapedPattern(for:)` or a bound such as `min(n, limit)` clears a value.
  A plain parameter is not a source; a value derived from one comes back as
  `ExternalInput.Derivation.parameter(_:path:)` carrying the parameter's index, which is what a
  later one-call-hop extension needs: find the function's call sites in the file and ask about
  the argument at that index. The limit is measured: 86 of 120 MCP integer arguments in
  businessMathMCP (72%) leave the function they arrive in.
- **Reassignment.** Only a binding's initialiser is followed.
- **Stored properties and globals**, except ArgumentParser properties.
- **A subscript's index.** `table[i]` is not external because `i` is.
- **Callback parameters.** `dataTask(with:) { data, _, _ in … }` — `data` is not a source.
- **A nested function** is another function, with its own scope.
- **Block scope.** Every earlier binding in the function is in scope, so a binding in an earlier
  sibling block can shadow. That over-reports; it does not hide a source.

### How the next rules consume it

`security.regex-from-input` is the first consumer: it reports a pattern whose
`ExternalInputFile/trace(of:)` is non-nil and names the kind and evidence in its message. The
rules queued behind it read the same answer differently:

```
// open-redirect (AStringThatEndsALineStartsAnother §3.3): the redirect target
if let trace = file.trace(of: target), trace.kind == .requestContent { error } else if nonLiteral { warning }

// bounded-work / loop bound (ACountFromOutsideNeedsACeiling): an integer reaching a work bound
if let trace = file.trace(of: bound) {
    severity = trace.kind.reach == .network ? .error : .warning   // §3.4: reach decides severity
}

// int-trap (ATrapIsAnOutage §3.2): only the source under a name is "external"
if let trace = file.trace(of: operand), trace.isDirect { … }

// error-detail (AnErrorIsNotAResponse §9): reflected request content is not disclosure
if file.trace(of: reasonPart)?.kind == .requestContent { not this rule }
```

The one-call hop, when a rule needs it, starts from `.parameter(p, path:)`: for a `private` or
`fileprivate` function, take every call to it in the file and classify argument `p.index` with
the same ``ExternalInputFile``.

### Asking for the syntax, not the description

``ExternalInputFile/scope(at:)`` describes each binding's initialiser as an
`ExternalInput.Expression`: enough to decide where a value came from, and deliberately without a
position or a literal's text. A rule that must *point at* the initialiser, or read the literal in
it, asks ``ExternalInputFile/bindingSites(at:)`` instead and gets a ``FunctionBindings``: the same
bindings, each a ``BindingSite`` holding the initialiser's syntax. `scope(at:)` is built from that
collection, so there is one definition of "in scope".

`FunctionBindings` is collected once for a function and then asked by name and point
(``FunctionBindings/binding(of:before:)``), so a rule that asks about every call in a function —
`security.ssrf` resolves each call's arguments to find the URL a request is made with — does not
walk the function once per question.

## Topics

### Reading a file

- ``ExternalInputFile``

### Bindings as syntax

- ``FunctionBindings``
- ``BindingSite``
