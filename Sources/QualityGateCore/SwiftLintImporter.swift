import Foundation
import Yams

/// Phase 4c §1 — the `.swiftlint.yml` → `.quality-gate.yml` migration.
///
/// Reads a SwiftLint configuration and produces a quality-gate fragment:
/// rules the config names are mapped to native equivalents where they
/// exist, `custom_rules` translate verbatim to Tier-1 `customRules:`, and
/// everything else lands in an honest unmapped report — the migration is
/// one command and tells the truth about its gaps.
public enum SwiftLintImporter {

    /// The importer's partition of one SwiftLint config.
    public struct ImportResult: Sendable, Equatable {
        /// SwiftLint rule id → native checker/rule id, for every named rule
        /// with a native equivalent.
        public let mapped: [String: String]
        /// `custom_rules` translated to Tier-1 custom rules, verbatim.
        public let translated: [CustomRuleConfig]
        /// Named rules with no native equivalent — the honest tail.
        public let unmapped: [String]
        /// The ready-to-paste `.quality-gate.yml` fragment.
        public let fragment: String
    }

    /// The importer cannot read the given YAML.
    public enum ImportError: Error, Equatable {
        /// The document is not a YAML mapping (or is not YAML at all).
        case notAMapping
    }

    /// SwiftLint rule id → native equivalent. The head of real-world
    /// SwiftLint usage; the tail is the unmapped report's job.
    static let ruleMap: [String: String] = [
        "force_unwrapping": "safety",
        "force_cast": "safety",
        "force_try": "safety",
        "empty_count": "idiom.empty-count",
        "redundant_optional_initialization": "idiom.redundant-optional-init",
        "redundant_nil_coalescing": "idiom.redundant-nil-coalescing",
        "redundant_discardable_let": "idiom.redundant-discardable-let",
        "syntactic_sugar": "idiom.syntactic-sugar",
        "shorthand_operator": "idiom.shorthand-operator",
        "identifier_name": "idiom.identifier-name",
        "type_name": "idiom.type-name",
        "todo": "idiom.todo-policy",
        "file_length": "idiom.file-length",
        "function_body_length": "idiom.function-body-length",
        "line_length": "idiom.line-length",
        "trailing_whitespace": "idiom.trailing-whitespace",
        "trailing_newline": "idiom.trailing-newline",
        "vertical_whitespace": "idiom.vertical-whitespace",
        "unused_closure_parameter": "idiom.unused-closure-parameter",
        "implicit_getter": "idiom.implicit-getter",
        "redundant_string_enum_value": "idiom.redundant-string-enum-value",
        "legacy_random": "idiom.legacy-random",
        "contains_over_first_not_nil": "idiom.contains-over-first",
        "cyclomatic_complexity": "complexity",
        "function_parameter_count": "smells",
        "nesting": "smells",
        "type_body_length": "smells",
        "closure_body_length": "smells",
    ]

    /// Top-level SwiftLint keys that are configuration structure, not rules.
    static let structuralKeys: Set<String> = [
        "disabled_rules", "opt_in_rules", "only_rules", "custom_rules",
        "analyzer_rules", "included", "excluded", "reporter", "strict",
        "lenient", "warning_threshold", "allow_zero_lintable_files",
        "swiftlint_version", "cache_path", "use_nested_configs",
    ]

    /// SwiftLint threshold key → (fragment section, quality-gate knob).
    static let thresholdMap: [String: (section: String, knob: String)] = [
        "line_length": ("idiom", "maxLineLength"),
        "file_length": ("idiom", "maxFileLength"),
        "function_body_length": ("idiom", "maxFunctionBodyLength"),
        "function_parameter_count": ("smells", "maxParameterCount"),
        "nesting": ("smells", "maxNestingDepth"),
        "type_body_length": ("smells", "maxTypeBodyLength"),
        "closure_body_length": ("smells", "maxClosureLength"),
    ]

    /// Imports one SwiftLint YAML document.
    ///
    /// - Parameter yaml: The `.swiftlint.yml` contents.
    /// - Returns: The mapped/translated/unmapped partition and the fragment.
    /// - Throws: `ImportError.notAMapping` for non-mapping documents; Yams
    ///   errors for unparsable input.
    public static func importConfig(yaml: String) throws -> ImportResult {
        guard let document = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ImportError.notAMapping
        }

        let disabled = Set(stringList(document["disabled_rules"]))
        var named = Set(stringList(document["opt_in_rules"]))
        named.formUnion(stringList(document["only_rules"]))
        for key in document.keys where !structuralKeys.contains(key) {
            named.insert(key)
        }
        named.subtract(disabled)

        var mapped: [String: String] = [:]
        var unmapped: [String] = []
        for rule in named {
            if let native = ruleMap[rule] {
                mapped[rule] = native
            } else {
                unmapped.append(rule)
            }
        }
        unmapped.sort()

        let translated = customRules(from: document["custom_rules"])
        let fragment = renderFragment(
            document: document, mapped: mapped,
            translated: translated, unmapped: unmapped)
        return ImportResult(
            mapped: mapped, translated: translated,
            unmapped: unmapped, fragment: fragment)
    }

    // MARK: - custom_rules translation (4b Tier 1)

    /// Translates SwiftLint `custom_rules` entries verbatim.
    static func customRules(from value: Any?) -> [CustomRuleConfig] {
        guard let rules = value as? [String: Any] else { return [] }
        var translated: [CustomRuleConfig] = []
        for (name, body) in rules.sorted(by: { $0.key < $1.key }) {
            guard let fields = body as? [String: Any],
                  let pattern = fields["regex"] as? String else { continue }
            let severity: Diagnostic.Severity =
                (fields["severity"] as? String) == "error" ? .error : .warning
            translated.append(CustomRuleConfig(
                id: name,
                pattern: pattern,
                include: stringList(fields["included"]),
                exclude: stringList(fields["excluded"]),
                message: (fields["message"] as? String) ?? name,
                severity: severity))
        }
        return translated
    }

    // MARK: - Fragment rendering

    /// Renders the ready-to-paste `.quality-gate.yml` fragment, unmapped
    /// report included as comments — visible in the artifact, not just in
    /// the terminal scrollback.
    static func renderFragment(
        document: [String: Any],
        mapped: [String: String],
        translated: [CustomRuleConfig],
        unmapped: [String]
    ) -> String {
        var lines: [String] = [
            "# Generated by `quality-gate import-swiftlint`.",
            "# Mapped \(mapped.count) SwiftLint rule(s) to native checkers; translated \(translated.count) custom rule(s); \(unmapped.count) unmapped.",
        ]

        var sections: [String: [String]] = [:]
        for (rule, target) in thresholdMap {
            guard let value = thresholdValue(document[rule], rule: rule) else { continue }
            sections[target.section, default: []].append("  \(target.knob): \(value)")
        }
        if let identifier = document["identifier_name"],
           let minLength = thresholdValue((identifier as? [String: Any])?["min_length"], rule: "min_length") {
            sections["idiom", default: []].append("  minIdentifierLength: \(minLength)")
        }
        for section in sections.keys.sorted() {
            lines.append("\(section):")
            lines.append(contentsOf: (sections[section] ?? []).sorted())
        }

        if !translated.isEmpty {
            lines.append("customRules:")
            for rule in translated {
                lines.append("  - id: \(rule.id)")
                lines.append("    pattern: '\(rule.pattern.replacingOccurrences(of: "'", with: "''"))'")
                lines.append("    message: \"\(rule.message)\"")
                lines.append("    severity: \(rule.severity.rawValue)")
                if !rule.include.isEmpty {
                    lines.append("    include:")
                    lines.append(contentsOf: rule.include.map { "      - \"\($0)\"" })
                }
                if !rule.exclude.isEmpty {
                    lines.append("    exclude:")
                    lines.append(contentsOf: rule.exclude.map { "      - \"\($0)\"" })
                }
            }
            lines.append("# Note: SwiftLint included/excluded path regexes carry over verbatim;")
            lines.append("# quality-gate custom rules match them as globs/prefixes — review path filters.")
        }

        if !unmapped.isEmpty {
            lines.append("# Unmapped SwiftLint rules — no native equivalent yet.")
            lines.append("# Keep SwiftLint for these, or cover them with a custom rule / 4b plugin:")
            lines.append(contentsOf: unmapped.map { "#   - \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    /// A SwiftLint value that is a list of strings (or a single string).
    static func stringList(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let single = value as? String { return [single] }
        if let anyList = value as? [Any] { return anyList.compactMap { $0 as? String } }
        return []
    }

    /// Extracts a numeric threshold: plain int, or `warning:`/`error:` tiers
    /// (warning wins — it is the tier that starts flagging). `nesting` uses
    /// `function_level`.
    static func thresholdValue(_ value: Any?, rule: String) -> Int? {
        if let number = value as? Int { return number }
        guard let tiers = value as? [String: Any] else { return nil }
        if rule == "nesting" {
            return tiers["function_level"] as? Int
        }
        return (tiers["warning"] as? Int) ?? (tiers["error"] as? Int)
    }
}
