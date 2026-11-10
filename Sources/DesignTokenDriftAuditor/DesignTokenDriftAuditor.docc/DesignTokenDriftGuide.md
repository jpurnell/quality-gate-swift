# Design Token Drift Guide

A design system is defined once and generated for every consumer. This checker fails a build when a project that opted in writes a value the tokens already own.

## Why this checker exists

The same orange was found in a stylesheet four ways, and a chart library carried its own blue where the house theme had another. Nothing was wrong in any one file. The values had been copied, and copies drift. `design-token-drift` turns each copy into a finding, with the token that should have been used.

It is opt-in. It reads nothing and reports `skipped` until `designTokens.enabled` is `true`, so a project that has not adopted the tokens is not judged by them. It runs nothing and reads files only.

## What it flags

In Swift, with SwiftSyntax:

- `design-token.hex-colour`: a `#RRGGBB` string, `Color(hex: "E77500")`, `Color(hex: 0xE77500)`, `RGB(rgb: 0xFF8D28)`, or a `0xRRGGBB` literal bound to a name such as `tint`, `accent` or `fillColor`.
- `design-token.rgb-initialiser`: `Color(red:green:blue:)`, `UIColor`, `NSColor`, `CGColor`, the white and HSB forms, and `.init(red:green:blue:)`, when at least one component is a number written in the source. Components that are all computed are colour maths and pass.
- `design-token.font`: `.system(size:)`, `Font.custom(_:size:)`, `UIFont.systemFont(ofSize:)`, `NSFont(name:size:)` and their relatives. A text style such as `.system(.body)` passes.
- `design-token.corner-radius`: a numeric literal as `cornerRadius`, as `.cornerRadius(8)`, or assigned to `layer.cornerRadius`.

In CSS and HTML, only under `designTokens.cssPaths`:

- `design-token.css-colour`: a hex or functional colour literal that is not in the token set.
- `design-token.css-font-size`: a `font-size` length that is not in the type scale.
- `design-token.css-column`: a fixed column track, a `repeat()` count other than the token's, a `column-width`, or a gap that is not the gutter.
- `design-token.css-token-copy` (warning): a literal that equals a token, written out. It is in step today and wrong at the next regeneration.

Each finding carries `path:line` and, where a token set is configured, the token to use: the nearest colour role with its distance, the nearest type role by size, or `container` or `control` for a radius.

## Who may write a value

Three kinds of file, each declared in `.quality-gate.yml`. A comment in a source file never suppresses a finding.

```yaml
designTokens:
  enabled: true
  exemptPackagePaths: ["Vendor/DesignTokens"]
  exemptPaletteFiles: ["Sources/WineTaster/WinePalette.swift"]
  exemptTestPaths: ["**/Tests/**"]
  cssPaths: ["Assets/css/**"]
  tokenFiles: ["Assets/css/tokens.css"]
```

Paths are globs relative to the project root. `**` crosses directories, `*` and `?` stay inside one, and a pattern that names a directory covers everything beneath it.

- `exemptPackagePaths` is the tokens package, where the values are defined.
- `exemptPaletteFiles` is an app's own palette, and it is declared twice: listed here, and marked in the file. The mark is DesignTokens 0.8.0's: a type or extension whose inheritance clause lists `AppPaletteSource`, with exactly one `AppPalette(id: "<literal>"` call in the file. The checker reads it syntactically and does not depend on the package. A comment is not a marker. The exemption covers colour literals only; fonts and radii still apply in the file. Every run validates it: a missing file is `design-token.palette-missing`, a Swift file without the marker is `design-token.palette-no-marker`, a wrong shape is `design-token.palette-multiple-markers` or `design-token.palette-bad-id`, a repeated id is `design-token.palette-duplicate-id`, and a palette no test mentions with `validate(` and `isConformant` is a warning, `design-token.palette-untested`. A marked file that is not listed is a note: the marker cannot grant its own exemption. A CSS palette has no marker, so it must define at least one colour (`design-token.palette-empty`).
- `exemptTestPaths` is empty by default, which holds tests to the rule.
- `tokenFiles` are the generated token files. They are read for the token set and are not scanned.

All three exemption lists appear in the run's exclusion report. A misspelt key in the section is an error, not a silent opt-out.

## What a clean run says

Every enabled run ends with a `design-token.coverage` note: files read, files exempt by category, tokens loaded, palette files validated. A clean pass states its own scope.

A configuration that cannot work is a finding, not a pass: `cssPaths` with no `tokenFiles`, a token file that matches nothing, or one from which no tokens could be read are all `design-token.config` errors.

## Limits

The analysis is syntactic. A colour built from a constant defined elsewhere is not seen, and `0xRRGGBB` counts as a colour only by the label or name it sits on. Named CSS colours such as `white` are not flagged, and the `font` shorthand is not parsed for a size. The proposal, `DesignTokenDriftIsAFinding.md`, lists what is open.
