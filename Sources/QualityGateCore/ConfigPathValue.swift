import Foundation

/// Why a path written in `.quality-gate.yml` cannot be used as written.
///
/// ## Why this exists
///
/// Two repositories set `consistency.corpusPath: ${ORG_JUDGEMENT_CORPUS:-}` so that no
/// absolute path would sit in the file. Nothing in the gate expands that. The string went
/// to the corpus writer verbatim, the writer created a directory *literally named*
/// `${ORG_JUDGEMENT_CORPUS:-}` inside each checkout, and three weeks of telemetry landed
/// there instead of in the corpus. `consistency` then found that directory, found no pulse
/// in it, and reported the skip as a pass.
///
/// ## Why refuse rather than expand
///
/// Across every `.quality-gate.yml` in the portfolio — 99 files — those two lines were the
/// only values containing `$` or `~`. Nothing relies on expansion, so adding it would be
/// new surface with its own failure modes (an unset variable, a variable set in a terminal
/// and absent in a hook, a default that silently differs per machine) in exchange for no
/// existing use. A refusal that names the key, the value and the fix costs one edit, once.
public struct ConfigPathProblem: Error, Equatable, Sendable {

    /// What is wrong with the value.
    public enum Reason: Equatable, Sendable {
        /// The value is empty or whitespace. An empty path silently means "here".
        case empty
        /// The value contains this shell-style reference — `$VAR`, `${VAR}`,
        /// `${VAR:-default}` or `$(command)`.
        case shellReference(String)
        /// The value starts with `~`, which only a shell turns into a home directory.
        case homeShorthand
    }

    /// The configuration key, dotted from the top of the file — `consistency.corpusPath`.
    public let key: String
    /// The value exactly as written.
    public let value: String
    /// What is wrong with it.
    public let reason: Reason

    /// Creates a problem record.
    public init(key: String, value: String, reason: Reason) {
        self.key = key
        self.value = value
        self.reason = reason
    }

    /// What to print: the key, the value, what the gate would have done with it, and the fix.
    public var message: String {
        let fix = "Write the path itself, absolute or relative to the repository root."
        switch reason {
        case .empty:
            return "`\(key)` is set to an empty value. An empty path is not a location. "
                + "Remove the key to leave it unset, or write the path."
        case .shellReference(let reference):
            return "`\(key)` is set to `\(value)`, and `\(reference)` is shell syntax. "
                + "The gate does not expand environment variables in `.quality-gate.yml`: "
                + "used as written, this names a directory literally called `\(value)`. \(fix)"
        case .homeShorthand:
            return "`\(key)` is set to `\(value)`, and a leading `~` is shell shorthand. "
                + "The gate does not expand it: used as written, this names a directory "
                + "literally called `~`. \(fix)"
        }
    }
}

/// The one rule every path-valued configuration key is held to.
public enum ConfigPathValue {

    /// Judges one value.
    ///
    /// Deliberately narrow about `$`: only `$` followed by a name, `{` or `(` reads as a
    /// reference. A trailing `$`, or `$` before a digit, is an unusual file name rather
    /// than something a shell was expected to resolve, and refusing it would be the gate
    /// objecting to a path that means what it says.
    ///
    /// - Parameters:
    ///   - key: The dotted configuration key, used in the message.
    ///   - value: The value as decoded.
    /// - Returns: The problem, or `nil` when the value can be used as written.
    public static func problem(key: String, value: String) -> ConfigPathProblem? {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ConfigPathProblem(key: key, value: value, reason: .empty)
        }
        if let reference = firstShellReference(in: value) {
            return ConfigPathProblem(key: key, value: value, reason: .shellReference(reference))
        }
        if value.hasPrefix("~") {
            return ConfigPathProblem(key: key, value: value, reason: .homeShorthand)
        }
        return nil
    }

    /// The first `$NAME`, `${…}` or `$(…)` in `value`, as written.
    static func firstShellReference(in value: String) -> String? {
        let characters = Array(value)
        for (index, character) in characters.enumerated() where character == "$" {
            let rest = characters[(index + 1)...]
            guard let next = rest.first else { return nil }
            if next == "{" || next == "(" {
                let closer: Character = next == "{" ? "}" : ")"
                // An unterminated `${` is still a reference someone meant; report what
                // is there rather than letting a typo through as a literal.
                let end = rest.firstIndex(of: closer) ?? characters.index(before: characters.endIndex)
                return String(characters[index...end])
            }
            if isNameStart(next) {
                let name = rest.prefix { isNameStart($0) || $0.isNumber }
                return "$" + String(name)
            }
        }
        return nil
    }

    private static func isNameStart(_ character: Character) -> Bool {
        character == "_" || (character.isASCII && character.isLetter)
    }
}

// MARK: - Every path-valued key

extension Configuration {

    /// One path-valued key and what the file set it to.
    public struct PathValue: Equatable, Sendable {
        /// The dotted key; list elements carry their index, as `vendorPaths[0]`.
        public let key: String
        /// The value as decoded.
        public let value: String
    }

    /// Every value in this configuration that names a file, a directory or a path pattern.
    ///
    /// The single list. A key added to the schema that holds a path belongs here, and
    /// ``pathValueProblems`` then covers it with no further work — which is the point of
    /// keeping the rule in one place rather than at each reader.
    ///
    /// Computed from the current field values rather than recorded during decoding, so a
    /// CLI override (`--telemetry-corpus-path`) is judged by the same rule as the file.
    public var pathValues: [PathValue] {
        var values: [PathValue] = []
        func add(_ key: String, _ value: String?) {
            if let value { values.append(PathValue(key: key, value: value)) }
        }
        func add(_ key: String, _ list: [String]) {
            for (index, value) in list.enumerated() {
                values.append(PathValue(key: "\(key)[\(index)]", value: value))
            }
        }

        add("excludePatterns", excludePatterns)
        add("vendorPaths", vendorPaths)
        add("status.guidelinesPath", status.guidelinesPath)
        add("status.masterPlanPath", status.masterPlanPath)
        add("memoryBuilder.guidelinesPath", memoryBuilder.guidelinesPath)
        add("releaseReadiness.changelogPath", releaseReadiness.changelogPath)
        add("releaseReadiness.readmePath", releaseReadiness.readmePath)
        add("fpSafety.allowedFiles", fpSafety.allowedFiles)
        add("stochasticDeterminism.exemptFiles", stochasticDeterminism.exemptFiles)
        add("memoryLifecycle.exemptFiles", memoryLifecycle.exemptFiles)
        add("mcpReadiness.additionalPaths", mcpReadiness.additionalPaths)
        add("mcpReadiness.excludePaths", mcpReadiness.excludePaths)
        add("boundedIO.kernelPath", boundedIO.kernelPath)
        add("appIntentsReadiness.excludePaths", appIntentsReadiness.excludePaths)
        add("xcodeBuild.project", xcodeBuild.project)
        add("xcodeBuild.workspace", xcodeBuild.workspace)
        add("consistency.corpusPath", consistency.corpusPath)
        add("ijs.corpusPath", ijs.corpusPath)
        add("legibility.artifactPath", legibility.artifactPath)
        add("dependencyAudit.advisorySnapshotPath", dependencyAudit.advisorySnapshotPath)
        for (index, plugin) in plugins.enumerated() {
            add("plugins[\(index)].run", plugin.run)
        }
        add("doc-code.moduleSearchPath", docCode.moduleSearchPath)
        add("doc-code.headerSearchPaths", docCode.headerSearchPaths)
        add("doc-code.librarySearchPaths", docCode.librarySearchPaths)
        add("doc-generated.additionalFiles", docGenerated.additionalFiles)
        return values
    }

    /// Every path-valued key whose value cannot be used as written, in ``pathValues`` order.
    public var pathValueProblems: [ConfigPathProblem] {
        pathValues.compactMap { ConfigPathValue.problem(key: $0.key, value: $0.value) }
    }
}
