import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// The language rules a target actually builds under.
public struct LanguageMode: Sendable, Equatable {

    /// The Swift language mode — `"5"`, `"6"`, … — or `nil` when it could not be read.
    public let swiftVersion: String?

    /// The full `swiftc` flag list, including `-swift-version` when it is known.
    public let flags: [String]

    /// Whether the mode was read from the manifest rather than left to the compiler.
    public var isDetermined: Bool { swiftVersion != nil }

    /// `swiftSettings` entries the reader did not recognise, by name.
    ///
    /// Reported rather than dropped. A setting the build applies and the auditor does not
    /// is a gap between what is checked and what ships, and silence about it reads exactly
    /// like support.
    public let unrecognisedSettings: [String]

    /// Why the mode is what it is, in one sentence, for the report.
    public let explanation: String
}

/// Reads a package manifest for the language mode and `swiftSettings` of one target.
///
/// This exists because the alternative — assuming — is wrong in both directions. Checking
/// documentation under **weaker** rules than the build is how an actor method returning a
/// non-`Sendable` type passed for months: in the compiler's default mode the violation is a
/// warning, and the auditor only collects errors. Checking under **stronger** rules hands a
/// package errors its own build never raises, and the documentation then gets "fixed" to
/// satisfy a rule nobody adopted.
///
/// The manifest is parsed with SwiftSyntax rather than matched with regular expressions,
/// because real manifests build their target lists conditionally — `var targets: [Target]`,
/// `#if !os(Linux)`, `targets.append(…)` — and a parser that only reads the literal array
/// passed to `Package(…)` finds nothing in them.
public enum ManifestLanguageMode {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocCodeAuditor")

    /// Reads the mode for `target` from a manifest's text.
    ///
    /// - Parameters:
    ///   - manifest: The full text of `Package.swift`.
    ///   - target: The target whose settings apply — the module the catalogue documents.
    /// - Returns: The mode, with `swiftVersion == nil` when the manifest yielded no
    ///   tools-version and no explicit language mode.
    public static func read(manifest: String, target: String) -> LanguageMode {
        let tree = Parser.parse(source: manifest)
        let collector = ManifestCollector(target: target)
        collector.walk(tree)

        let toolsVersion = self.toolsVersion(in: manifest)
        let derived = toolsVersion.flatMap(languageMode(forToolsVersion:))
        let version = collector.targetLanguageMode ?? collector.packageLanguageMode ?? derived

        var flags: [String] = []
        if let version {
            flags += ["-swift-version", version]
        }
        if let toolsVersion {
            // `PackageDescription`'s API is gated on the `_PackageDescription` availability
            // domain, which this flag sets and which is otherwise empty. Without it every
            // documented `Package.swift` excerpt fails with `'package(url:branch:)' is
            // unavailable` — a fact about how the manifest API is versioned, not a defect in
            // the documentation, and one whose natural "fix" is to mark the block
            // illustrative.
            flags += ["-package-description-version", toolsVersion]
        }
        flags += collector.flags

        let explanation: String
        if let mode = collector.targetLanguageMode {
            explanation = "Swift \(mode) mode, from the target's own swiftSettings in Package.swift."
        } else if let mode = collector.packageLanguageMode {
            explanation = "Swift \(mode) mode, from the package's swiftLanguageModes in Package.swift."
        } else if let derived, let toolsVersion {
            explanation = "Swift \(derived) mode, implied by swift-tools-version \(toolsVersion)."
        } else {
            explanation = """
                The language mode could not be read from Package.swift, so fenced code was \
                typechecked under the compiler's default rules. Those may be weaker than the \
                rules this package builds under, which would let a real defect pass.
                """
        }

        return LanguageMode(
            swiftVersion: version,
            flags: flags,
            unrecognisedSettings: collector.unrecognised,
            explanation: explanation)
    }

    /// Reads the mode from the manifest at a project root.
    ///
    /// - Returns: The mode, or an undetermined mode when the manifest is missing or
    ///   unreadable. Never falls back to the strictest available rules.
    public static func read(projectRoot: URL, target: String) -> LanguageMode {
        let manifest = projectRoot.appendingPathComponent("Package.swift")
        do {
            // SAFETY: CLI tool reads the project's own manifest to mirror its build settings
            return read(manifest: try String(contentsOf: manifest, encoding: .utf8), target: target)
        } catch {
            logger.warning("Could not read \(manifest.path, privacy: .public) for the language mode; falling back to the compiler's default rules: \(error.localizedDescription, privacy: .public)")
            return LanguageMode(
                swiftVersion: nil,
                flags: [],
                unrecognisedSettings: [],
                explanation: """
                    Package.swift at \(projectRoot.path) could not be read \
                    (\(error.localizedDescription)), so fenced code was typechecked under the \
                    compiler's default rules rather than the package's.
                    """)
        }
    }

    /// The `// swift-tools-version:` declaration, if the manifest opens with one.
    static func toolsVersion(in manifest: String) -> String? {
        for line in manifest.lines.prefix(4) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { continue }
            let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.lowercased().hasPrefix("swift-tools-version") else { continue }
            guard let colon = body.firstIndex(of: ":") else { continue }
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The language mode a tools version implies when nothing overrides it.
    ///
    /// SwiftPM ties the default mode to the manifest's tools version: 6.x manifests build in
    /// Swift 6 mode, 5.x in Swift 5, and the two 4.x spellings keep their own.
    static func languageMode(forToolsVersion toolsVersion: String) -> String? {
        let major = toolsVersion.prefix { $0.isNumber }
        switch major {
        case "4":
            return toolsVersion.hasPrefix("4.2") ? "4.2" : "4"
        case "5":
            return "5"
        default:
            return major.isEmpty ? nil : String(major)
        }
    }
}

/// Walks a manifest for the target's `swiftSettings` and the package's language modes.
final class ManifestCollector: SyntaxVisitor {

    private let target: String

    /// `.swiftLanguageMode(.v5)` on the target itself.
    private(set) var targetLanguageMode: String?

    /// `swiftLanguageModes: [.v5]` on the `Package(…)` call.
    private(set) var packageLanguageMode: String?

    /// Compiler flags derived from the target's other settings.
    private(set) var flags: [String] = []

    /// Setting names with no known flag translation.
    private(set) var unrecognised: [String] = []

    init(target: String) {
        self.target = target
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if calleeName(node) == "Package", let modes = argument(named: "swiftLanguageModes", of: node) {
            packageLanguageMode = firstLanguageMode(in: modes)
        }
        if isTargetDeclaration(node), stringArgument(named: "name", of: node) == target,
           let settings = argument(named: "swiftSettings", of: node)?
               .as(ArrayExprSyntax.self) {
            read(settings: settings)
        }
        return .visitChildren
    }

    // MARK: - Settings

    private func read(settings: ArrayExprSyntax) {
        for element in settings.elements {
            guard let call = element.expression.as(FunctionCallExprSyntax.self),
                  let name = memberName(call.calledExpression) else {
                // `.enableUpcomingFeature` without a call — or any expression shape the
                // reader does not model — still deserves to be named in the report.
                if let member = element.expression.as(MemberAccessExprSyntax.self) {
                    unrecognised.append(member.declName.baseName.text)
                }
                continue
            }

            switch name {
            case "swiftLanguageMode", "swiftLanguageVersion":
                if let mode = call.arguments.first.flatMap({ languageMode(from: $0.expression) }) {
                    targetLanguageMode = mode
                }
            case "enableUpcomingFeature":
                if let feature = firstStringLiteral(call) {
                    flags += ["-enable-upcoming-feature", feature]
                }
            case "enableExperimentalFeature":
                if let feature = firstStringLiteral(call) {
                    flags += ["-enable-experimental-feature", feature]
                }
            case "define":
                if let symbol = firstStringLiteral(call) {
                    flags.append("-D\(symbol)")
                }
            case "unsafeFlags":
                if let array = call.arguments.first?.expression.as(ArrayExprSyntax.self) {
                    flags += array.elements.compactMap { stringValue($0.expression) }
                }
            case "strictMemorySafety":
                flags.append("-strict-memory-safety")
            case "interoperabilityMode":
                if let mode = call.arguments.first.flatMap({ memberName($0.expression) }) {
                    flags.append("-cxx-interoperability-mode=\(mode.lowercased() == "cxx" ? "default" : mode)")
                }
            case "treatAllWarnings", "treatWarning", "headerSearchPath", "linkedLibrary", "linkedFramework":
                // Deliberately ignored: they change diagnostics or linking, and this checker
                // only typechecks. Named here so the omission is a decision, not an oversight.
                break
            default:
                unrecognised.append(name)
            }
        }
    }

    // MARK: - Shapes

    /// Whether this call declares a target of any kind.
    private func isTargetDeclaration(_ node: FunctionCallExprSyntax) -> Bool {
        guard let name = calleeName(node) else { return false }
        return ["target", "executableTarget", "testTarget", "macro"].contains(name)
    }

    /// The called function's name, whether spelled `.target(…)` or `Target.target(…)`.
    private func calleeName(_ node: FunctionCallExprSyntax) -> String? {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        if let identifier = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            return identifier.baseName.text
        }
        return nil
    }

    private func memberName(_ expression: some ExprSyntaxProtocol) -> String? {
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return memberName(call.calledExpression)
        }
        return nil
    }

    private func argument(named label: String, of node: FunctionCallExprSyntax) -> ExprSyntax? {
        node.arguments.first { $0.label?.text == label }?.expression
    }

    private func stringArgument(named label: String, of node: FunctionCallExprSyntax) -> String? {
        argument(named: label, of: node).flatMap { stringValue($0) }
    }

    private func firstStringLiteral(_ call: FunctionCallExprSyntax) -> String? {
        call.arguments.first.flatMap { stringValue($0.expression) }
    }

    private func stringValue(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
        return literal.segments.compactMap { segment in
            segment.as(StringSegmentSyntax.self)?.content.text
        }.joined()
    }

    /// `.v5` → `"5"`, `.v6` → `"6"`, `.version("7")` → `"7"`.
    private func languageMode(from expression: ExprSyntax) -> String? {
        if let call = expression.as(FunctionCallExprSyntax.self),
           memberName(call.calledExpression) == "version" {
            return firstStringLiteral(call)
        }
        guard let name = memberName(expression), name.hasPrefix("v") else { return nil }
        return String(name.dropFirst())
    }

    private func firstLanguageMode(in expression: ExprSyntax) -> String? {
        guard let array = expression.as(ArrayExprSyntax.self) else {
            return languageMode(from: expression)
        }
        return array.elements.compactMap { languageMode(from: $0.expression) }.first
    }
}
