import Foundation
import QualityGateCore
import QualityGateLogging

/// One run of the checker over one project: resolve what is exempt, validate the declarations,
/// read the rest.
struct DriftRun {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "DriftRun")
    let config: DesignTokensConfig
    let files: ProjectFiles
    private(set) var diagnostics: [Diagnostic] = []

    private var tokens = TokenSet()
    private var swiftScanned = 0
    private var cssScanned = 0
    private var exemptPackage = 0
    private var exemptPalette = 0
    private var exemptTest = 0

    init(config: DesignTokensConfig, files: ProjectFiles) {
        self.config = config
        self.files = files
    }

    mutating func execute() {
        let tokenFiles = loadTokens()
        let paletteFiles = validatePalettes()
        scan(tokenFiles: Set(tokenFiles), paletteFiles: Set(paletteFiles))
        diagnostics.append(coverageNote(paletteDeclarations: paletteFiles.count))
    }

    // MARK: Tokens

    private mutating func loadTokens() -> [String] {
        let matched = files.matching(config.tokenFiles)
        if !config.cssPaths.isEmpty, config.tokenFiles.isEmpty {
            diagnostics.append(configError(
                "designTokens.cssPaths is set but designTokens.tokenFiles is empty: CSS cannot be compared with a token set that was not named.",
                fix: "List the generated tokens.css (or DesignTokens' Generated/ CSS) under designTokens.tokenFiles."))
        }
        for pattern in config.tokenFiles where files.matching([pattern]).isEmpty {
            diagnostics.append(configError(
                "designTokens.tokenFiles entry '\(pattern)' matches no file.",
                fix: "Point it at the generated token file, or remove it."))
        }
        let texts = matched.compactMap { read($0) }
        tokens = TokenSet.parse(css: texts.joined(separator: "\n"))
        if !matched.isEmpty, tokens.isEmpty {
            diagnostics.append(configError(
                "designTokens.tokenFiles matched \(matched.count) file(s) but no design tokens could be read from them.",
                fix: "The token files must declare custom properties such as --accent: #RRGGBB;."))
        }
        return matched
    }

    // MARK: Palettes

    /// Each declared entry must match a file, and each matched file must be a palette.
    ///
    /// A Swift file is a palette when it carries DesignTokens' `AppPaletteSource` marker in its
    /// contract shape; a CSS or HTML file, which has no marker, when it defines a colour.
    private mutating func validatePalettes() -> [String] {
        var palettes: [String] = []
        var seenIDs: [String: String] = [:]
        var swiftPalettes: [(path: String, name: String?)] = []
        for pattern in config.exemptPaletteFiles {
            let matched = files.matching([pattern])
            guard !matched.isEmpty else {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "Declared app-palette file '\(pattern)' no longer exists: an exemption that points at nothing.",
                    filePath: pattern, ruleId: "design-token.palette-missing",
                    suggestedFix: "Remove '\(pattern)' from designTokens.exemptPaletteFiles, or restore the file."))
                continue
            }
            for path in matched {
                palettes.append(path)
                guard let text = read(path) else { continue }
                if files.isSwift(path) {
                    let marker = SwiftDrift.paletteMarker(source: text)
                    diagnostics += markerFindings(marker, path: path, seenIDs: &seenIDs)
                    swiftPalettes.append((path, marker.conformers.first))
                } else if !definesColour(path: path, text: text) {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "Declared app-palette file '\(path)' defines no colour: it exempts nothing, and would hide the next one added.",
                        filePath: files.absolutePath(path), ruleId: "design-token.palette-empty",
                        suggestedFix: "Remove it from designTokens.exemptPaletteFiles, or move the colours it should hold into it."))
                }
            }
        }
        diagnostics += untestedPalettes(swiftPalettes)
        return palettes
    }

    private func markerFindings(_ marker: PaletteMarker, path: String, seenIDs: inout [String: String]) -> [Diagnostic] {
        let file = files.absolutePath(path)
        func error(_ rule: String, _ message: String, _ fix: String) -> Diagnostic {
            Diagnostic(severity: .error, message: message, filePath: file, ruleId: rule, suggestedFix: fix)
        }
        guard marker.present else {
            return [error("design-token.palette-no-marker",
                "Declared app-palette file '\(path)' has no AppPaletteSource declaration: listing a file is not enough, and a comment is not a marker.",
                "Declare a type that conforms to AppPaletteSource (DesignTokens 0.8.0) in this file, or remove it from designTokens.exemptPaletteFiles.")]
        }
        var out: [Diagnostic] = []
        if marker.conformers.count > 1 {
            out.append(error("design-token.palette-multiple-markers",
                "'\(path)' has \(marker.conformers.count) AppPaletteSource declarations (\(marker.conformers.joined(separator: ", "))); the contract allows exactly one.",
                "Keep one palette per file."))
        }
        if marker.paletteCalls != 1 || marker.ids.count != 1 {
            out.append(error("design-token.palette-bad-id",
                "'\(path)' must contain exactly one AppPalette(id: \"<literal>\", ...) call; found \(marker.paletteCalls) call(s) and \(marker.ids.count) string-literal id(s).",
                "Write the palette id as a string literal in a single AppPalette call."))
        }
        for id in marker.ids {
            if let other = seenIDs[id] {
                out.append(error("design-token.palette-duplicate-id",
                    "Palette id '\(id)' in '\(path)' is already declared in '\(other)'.", "Palette ids are unique across the repository."))
            } else {
                seenIDs[id] = path
            }
        }
        return out
    }

    /// A palette nobody validates is the hole the marker exists to close; a warning, as the contract says.
    private mutating func untestedPalettes(_ palettes: [(path: String, name: String?)]) -> [Diagnostic] {
        let named = palettes.filter { $0.name != nil }
        guard !named.isEmpty else { return [] }
        let texts = files.relativePaths.filter { files.isSwift($0) }.compactMap { read($0) }
        return named.compactMap { palette in
            guard let name = palette.name else { return nil }
            let tested = texts.contains { $0.contains(name) && $0.contains("validate(") && $0.contains("isConformant") }
            guard !tested else { return nil }
            return Diagnostic(
                severity: .warning,
                message: "No file mentions \(name) with validate( and isConformant: an exempt palette nobody tests.",
                filePath: files.absolutePath(palette.path), ruleId: "design-token.palette-untested",
                suggestedFix: "Add a test that asserts \(name).validate().isConformant.")
        }
    }

    private func definesColour(path: String, text: String) -> Bool {
        if files.isCSS(path) || files.isHTML(path) { return CSSDrift.definesColour(text: text, isHTML: files.isHTML(path)) }
        return false
    }

    // MARK: Scan

    private mutating func scan(tokenFiles: Set<String>, paletteFiles: Set<String>) {
        for path in files.relativePaths {
            let isSwift = files.isSwift(path)
            let isStyle = files.isCSS(path) || files.isHTML(path)
            guard isSwift || (isStyle && inCSSScope(path)) else { continue }
            if tokenFiles.contains(path) { continue }
            if exempt(path, palettes: paletteFiles) { continue }
            guard let text = read(path) else { continue }
            let colourRules = !paletteFiles.contains(path)
            if isSwift {
                swiftScanned += 1
                diagnostics += SwiftDrift.analyze(
                    source: text, fileName: files.absolutePath(path), tokens: tokens, colourRules: colourRules)
                if colourRules, text.contains("AppPaletteSource"), SwiftDrift.paletteMarker(source: text).present {
                    diagnostics.append(undeclaredNote(path))
                }
            } else {
                cssScanned += 1
                diagnostics += CSSDrift.analyze(
                    text: text, fileName: files.absolutePath(path), isHTML: files.isHTML(path),
                    tokens: tokens, colourRules: colourRules)
            }
        }
    }

    /// The marker cannot grant its own exemption; only the config declares one.
    private func undeclaredNote(_ path: String) -> Diagnostic {
        Diagnostic(
            severity: .note,
            message: "'\(path)' carries the AppPaletteSource marker but is not listed in designTokens.exemptPaletteFiles, so its colour literals are still findings.",
            filePath: files.absolutePath(path), ruleId: "design-token.palette-undeclared",
            suggestedFix: "List it under designTokens.exemptPaletteFiles to declare it, or move the colours into a declared palette.")
    }

    private func inCSSScope(_ path: String) -> Bool {
        config.cssPaths.contains { PathGlob.matches($0, path: path) }
    }

    /// Counts the exemption that applies, in the order package, palette, test.
    private mutating func exempt(_ path: String, palettes: Set<String>) -> Bool {
        if config.exemptPackagePaths.contains(where: { PathGlob.matches($0, path: path) }) {
            exemptPackage += 1
            return true
        }
        if palettes.contains(path) { exemptPalette += 1 }
        if config.exemptTestPaths.contains(where: { PathGlob.matches($0, path: path) }) {
            exemptTest += 1
            return true
        }
        return false
    }

    // MARK: Reporting

    private mutating func read(_ path: String) -> String? {
        do {
            return try String(contentsOfFile: files.absolutePath(path), encoding: .utf8)
        } catch {
            Self.logger.warning("design-token-drift could not read \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            diagnostics.append(Diagnostic(
                severity: .warning, message: "Could not read '\(path)': \(error.localizedDescription). Findings in it are unknown, not absent.",
                filePath: files.absolutePath(path), ruleId: "design-token.unreadable"))
            return nil
        }
    }

    private func configError(_ message: String, fix: String) -> Diagnostic {
        Diagnostic(severity: .error, message: message, filePath: ".quality-gate.yml",
                   ruleId: "design-token.config", suggestedFix: fix)
    }

    /// What this run read and what it left out, so a clean pass states its own scope.
    private func coverageNote(paletteDeclarations: Int) -> Diagnostic {
        func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
        var parts = ["read \(plural(swiftScanned, "Swift file")) and \(plural(cssScanned, "CSS/HTML file"))"]
        parts.append("exempt: \(exemptPackage) in the tokens package, \(exemptTest) test; \(exemptPalette) declared palette file(s) read with the colour rules off")
        parts.append("\(plural(tokens.count, "token")) loaded")
        if !config.exemptPaletteFiles.isEmpty { parts.append("\(plural(paletteDeclarations, "palette file")) validated") }
        return Diagnostic(
            severity: .note, message: "design-token-drift: " + parts.joined(separator: "; ") + ".",
            ruleId: "design-token.coverage")
    }
}
