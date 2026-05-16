# 13 — Terminal UI (TUI) Development

Rules for building interactive full-screen terminal applications with SwiftCLIKit or equivalent terminal libraries.

## Rendering

### Cursor Positioning Over Newlines

Use explicit cursor positioning (`\033[row;1H`) for each line instead of relying on newline-based flow. Newline-based rendering breaks when any line wraps (exceeds terminal width), causing content to overflow and scroll state to desync from the visual output.

```swift
// WRONG: newline-based — wrapping lines corrupt the layout
let clipped = visibleLines.joined(separator: "\n")
print(ANSICodes.clearScreen + ANSICodes.home + clipped, terminator: "")

// RIGHT: cursor-positioned — each line placed at an explicit row
var output = ANSICodes.clearScreen
for (idx, line) in visibleLines.enumerated() {
    let truncated = ANSIStringMetrics.truncateVisible(line, to: cols)
    output += "\u{001B}[\(idx + 1);1H" + truncated
}
writeToStdout(output)
```

### Line Truncation

Every line written to the terminal must be truncated to the terminal's column width using `ANSIStringMetrics.truncateVisible`. This prevents wrapping even when ANSI escape sequences inflate the byte count beyond the visible character count.

### Terminal Width

Use `TerminalSize.current().columns` directly. Do not impose a minimum width floor above 20 — forcing `max(columns, 60)` causes line wrapping on narrower terminals while the logical line count stays low, breaking scroll clamp calculations.

## Output

### Direct Write Over Print

Use `write(STDOUT_FILENO, ...)` for frame output instead of `Swift.print`. Even with `setvbuf(stdout, nil, _IONBF, 0)`, Swift's print may buffer through a separate path. Direct write guarantees unbuffered, atomic output:

```swift
func writeToStdout(_ string: String) {
    let bytes = Array(string.utf8)
    bytes.withUnsafeBufferPointer { buffer in
        guard let ptr = buffer.baseAddress else { return }
        _ = write(1, ptr, buffer.count)
    }
}
```

### Alternate Screen

Always use `AlternateScreen()` (RAII) for full-screen TUIs. Hold the instance for the event loop lifetime — it restores the original screen on deallocation.

## Scroll and Clipping

### Content Splitting

When splitting rendered content into lines, strip trailing empty elements before computing content height:

```swift
var allLines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
while allLines.last?.isEmpty == true { allLines.removeLast() }
```

`ScreenBuffer.appendLine` appends `\n` after each line. The trailing `\n` produces an empty trailing element in `split`, which inflates the line count and miscalculates scroll bounds.

### Scroll Clamping

Clamp `scrollOffset` to `max(0, contentLines - terminalHeight + 1)` every frame, *after* rendering but *before* display. Content line count can change between frames (terminal resize, view switch).

### Scroll Indicator

Place the scroll percentage indicator using cursor positioning at a fixed screen location (e.g., bottom-right), not by appending to the last content line:

```swift
if allLines.count > rows {
    let maxScroll = max(1, allLines.count - rows)
    let pct = Int((Double(scrollOffset) / Double(maxScroll) * 100).rounded())
    output += "\u{001B}[\(rows);\(cols - 5)H" + ANSICodes.dim + "[\(pct)%]" + ANSICodes.reset
}
```

## Input Handling

### Mouse Support

Enable SGR mouse mode (`MouseMode.enable` / `MouseMode.disable`) for scroll wheel and click support. Always disable in the SIGINT handler and on clean exit.

### Signal Handlers

Signal handlers (SIGINT) cannot capture Swift context — they are C function pointers. Use `nonisolated(unsafe)` global flags with a `// Justification:` comment. Restore terminal state (cursor, mouse mode) inside the handler using direct `write(1, ...)`.

### State Machine

Separate input handling from rendering. Use a state machine (`DashboardState`) with:
- `handleInput(_:)` that mutates state without side effects
- A render pass that reads state and produces a frame string
- No direct terminal I/O inside state mutation

This makes input handling fully testable without a terminal.

## Testing

### State Machine Tests

Test all input paths: navigation (arrows), view switching (enter/escape), tab cycling (tab/backtab), scroll (arrow, mouse wheel, page up/down), click-to-select, quit signals.

### Render Tests

Verify rendered content:
- Contains expected text (project names, tab labels, data values)
- All lines fit within the specified width (`ANSIStringMetrics.visibleLength(line) <= width`)
- Content with many items exceeds a typical terminal height (confirming scroll is needed)

### No Integration Tests for Terminal I/O

Do not attempt to test the event loop or terminal output in unit tests. Test the state machine and renderers independently. The event loop is a thin integration layer.
