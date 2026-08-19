import Foundation
import IndexStoreInfra
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Flags credentials/tokens written to `UserDefaults` and points the developer
/// at the Keychain.
///
/// Secrets in `UserDefaults` land in a plaintext `.plist` inside the app
/// container — unencrypted at rest and included in device backups. For a
/// health/clinical product that is a concrete breach surface. Detection is
/// **AST-based** (SwiftSyntax): a `UserDefaults` `set(_:forKey:)` /
/// `setValue(_:forKey:)` call, or a `defaults[key] = value` subscript
/// assignment, whose key literal or stored-value identifier names a secret.
///
/// Precision guards keep false positives low: a stored `Bool`/`Int` literal is
/// a strong non-secret signal and is never flagged, matching is word-aware
/// (`tokenizer` is not `token`), and both a config `allowKeys` list and an
/// inline `// keychain:exempt` marker (recorded as a ``DiagnosticOverride``,
/// never silent) suppress a site.
public struct KeychainSecretsChecker: QualityChecker, Sendable {

    /// The checker identifier.
    public let id = "keychain-secrets"
    /// The human-readable name.
    public let name = "Keychain Secrets Checker"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Credentials/tokens written to `UserDefaults` (plaintext plist, backup-swept) instead of the Keychain — key- and value-name secret detection with a Bool/Int-value guard"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.safetySecurity

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Detection thresholds and vocabulary.
    let config: KeychainSecretsConfig
    /// Package root to scan; nil means the current working directory.
    let root: String?

    /// Creates the checker.
    ///
    /// - Parameters:
    ///   - config: Severity, allow-list, and extra secret nouns.
    ///   - root: Package root to scan (defaults to the working directory;
    ///     injectable for tests).
    public init(config: KeychainSecretsConfig = KeychainSecretsConfig(), root: String? = nil) {
        self.config = config
        self.root = root
    }

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or out-of-tree path
    /// among its inputs — so the same tree under the same gate binary yields the same verdict.
    /// `gateIdentityHash` folds in the binary's identity and the toolchain, so a rebuild or a
    /// compiler change invalidates every entry.
    ///
    /// `wholeSourceAndDocs` rather than `wholeSource`: it is the wider set, and over-including
    /// an input costs a cache miss while under-including one serves a stale pass.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Scans every Swift source under `Sources/` and `Tests/`.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let scanRoot = root ?? configuration.resolvedProjectRoot.path

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        for file in Self.swiftFiles(under: scanRoot) {
            // silent: an unreadable file cannot be scanned; skip it rather than fail the gate
            guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let findings = Self.analyze(source: source, filePath: file, config: config)
            diagnostics.append(contentsOf: findings.diagnostics)
            overrides.append(contentsOf: findings.overrides)
        }

        let status: CheckResult.Status
        if diagnostics.contains(where: { $0.severity == .error }) {
            status = .failed
        } else if diagnostics.contains(where: { $0.severity == .warning }) {
            status = .warning
        } else {
            status = .passed
        }

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            overrides: overrides,
            duration: ContinuousClock.now - startTime)
    }

    // MARK: - Engine (pure over its inputs; internal for tests)

    /// Every `UserDefaults`-secret finding in one source file, in line order.
    ///
    /// Two passes: the first records identifiers bound to a `UserDefaults`
    /// instance (so a later `defaults.set(...)` resolves to a real receiver,
    /// not a same-named method on something else); the second detects the
    /// secret writes.
    static func analyze(
        source: String,
        filePath: String,
        config: KeychainSecretsConfig
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let tree = Parser.parse(source: source)

        let binder = UserDefaultsBindingCollector(viewMode: .sourceAccurate)
        binder.walk(tree)

        let visitor = KeychainSecretsVisitor(
            config: config,
            filePath: filePath,
            source: source,
            tree: tree,
            userDefaultsVars: binder.names)
        visitor.walk(tree)

        let sorted = visitor.findings.sorted { lhs, rhs in
            let leftLine = lhs.lineNumber ?? 0
            let rightLine = rhs.lineNumber ?? 0
            if leftLine != rightLine { return leftLine < rightLine }
            return (lhs.columnNumber ?? 0) < (rhs.columnNumber ?? 0)
        }
        return (sorted, visitor.overrides)
    }

    /// Every `.swift` file under `Sources/` and `Tests/`, sorted for
    /// deterministic finding order.
    static func swiftFiles(under root: String) -> [String] {
        var files: [String] = []
        for dir in ["Sources", "Tests"] {
            let base = (root as NSString).appendingPathComponent(dir)
            guard let enumerator = FileManager.default.enumerator(atPath: base) else { continue }
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".swift") else { continue }
                files.append((base as NSString).appendingPathComponent(relative))
            }
        }
        return files.sorted()
    }
}

// MARK: - Receiver resolution helpers (shared by both passes)

/// True if `expr` denotes a `UserDefaults` instance by construction:
/// `UserDefaults.standard` (any `UserDefaults.<member>`) or a `UserDefaults(...)`
/// call. Parens, force-unwraps, and optional chains are unwrapped first.
func isUserDefaultsConstruction(_ expr: ExprSyntax) -> Bool {
    let inner = unwrapReceiver(expr)
    if let member = inner.as(MemberAccessExprSyntax.self),
       let base = member.base,
       base.as(DeclReferenceExprSyntax.self)?.baseName.text == "UserDefaults" {
        return true
    }
    if let call = inner.as(FunctionCallExprSyntax.self),
       call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "UserDefaults" {
        return true
    }
    return false
}

/// Strips parentheses, force-unwraps (`x!`), and optional chains (`x?`) from a
/// receiver expression, exposing the underlying reference.
func unwrapReceiver(_ expr: ExprSyntax) -> ExprSyntax {
    if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
       let only = tuple.elements.first {
        return unwrapReceiver(only.expression)
    }
    if let forced = expr.as(ForceUnwrapExprSyntax.self) {
        return unwrapReceiver(forced.expression)
    }
    if let optional = expr.as(OptionalChainingExprSyntax.self) {
        return unwrapReceiver(optional.expression)
    }
    return expr
}

// MARK: - Pass 1: collect UserDefaults-bound variable names

/// Records identifiers bound to a `UserDefaults` instance — by initializer
/// (`let d = UserDefaults.standard`) or by type annotation (`let d: UserDefaults`).
final class UserDefaultsBindingCollector: SyntaxVisitor {

    /// Names known to reference a `UserDefaults` instance.
    private(set) var names: Set<String> = []

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                continue
            }
            if let initializer = binding.initializer,
               isUserDefaultsConstruction(initializer.value) {
                names.insert(identifier)
            } else if let type = binding.typeAnnotation?.type {
                let written = type.trimmedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "?!"))
                if written == "UserDefaults" {
                    names.insert(identifier)
                }
            }
        }
        return .visitChildren
    }
}

// MARK: - Pass 2: detect secret writes

/// Detects `UserDefaults` writes whose key literal or stored-value identifier
/// names a secret.
final class KeychainSecretsVisitor: SyntaxVisitor {

    private let config: KeychainSecretsConfig
    private let filePath: String
    private let lines: [String]
    private let converter: SourceLocationConverter
    private let userDefaultsVars: Set<String>

    /// Secret nouns matched as a whole tokenized word (so `tokenizer` ≠ `token`).
    private let singleWords: Set<String>
    /// Secret nouns matched as a substring of the concatenated, normalized name
    /// (so `apiKey` → `apikey` matches even though neither `api` nor `key` is a
    /// secret on its own).
    private let compounds: [String]

    private(set) var findings: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    init(
        config: KeychainSecretsConfig,
        filePath: String,
        source: String,
        tree: SourceFileSyntax,
        userDefaultsVars: Set<String>
    ) {
        self.config = config
        self.filePath = filePath
        self.lines = source.lines
        self.converter = SourceLocationConverter(fileName: filePath, tree: tree)
        self.userDefaultsVars = userDefaultsVars

        // Built-in vocabulary. Extra patterns are matched as whole words, which
        // covers the common single-noun case (jwt, otp, pin) without the
        // substring false positives a bare `contains` would invite.
        let extras = config.extraPatterns.map(Self.normalize)
        self.singleWords = Set(["token", "password", "passwd", "secret", "credential", "bearer"] + extras)
        self.compounds = ["apikey", "authtoken", "accesstoken", "refreshtoken", "privatekey", "clientsecret", "sessionkey"]

        super.init(viewMode: .sourceAccurate)
    }

    // MARK: set(_:forKey:) / setValue(_:forKey:)

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return .visitChildren
        }
        let method = member.declName.baseName.text
        guard method == "set" || method == "setValue" else { return .visitChildren }
        guard let base = member.base, isUserDefaultsReceiver(base) else { return .visitChildren }

        guard let first = node.arguments.first, first.label == nil else { return .visitChildren }
        let valueExpr = first.expression
        guard let keyArg = node.arguments.first(where: { $0.label?.text == "forKey" }) else {
            return .visitChildren
        }
        evaluate(keyExpr: keyArg.expression, valueExpr: valueExpr, at: Syntax(node))
        return .visitChildren
    }

    // MARK: defaults[key] = value

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self) else {
            return .visitChildren
        }
        guard let subscriptCall = elements[0].as(SubscriptCallExprSyntax.self),
              isUserDefaultsReceiver(subscriptCall.calledExpression),
              let keyArg = subscriptCall.arguments.first else {
            return .visitChildren
        }
        evaluate(keyExpr: keyArg.expression, valueExpr: elements[2], at: Syntax(subscriptCall))
        return .visitChildren
    }

    // MARK: - Evaluation

    /// True if `expr` resolves to a `UserDefaults` instance: a construction
    /// (`UserDefaults.standard` / `UserDefaults(...)`) or a reference to a
    /// variable Pass 1 bound to one.
    private func isUserDefaultsReceiver(_ expr: ExprSyntax) -> Bool {
        if isUserDefaultsConstruction(expr) { return true }
        let inner = unwrapReceiver(expr)
        if let name = inner.as(DeclReferenceExprSyntax.self)?.baseName.text {
            return userDefaultsVars.contains(name)
        }
        return false
    }

    /// Applies the precision guards, then records a finding if the key or value
    /// names a secret. A stored `Bool`/`Int` literal short-circuits to no
    /// finding (a stored `true`/`3` is not a credential).
    private func evaluate(keyExpr: ExprSyntax, valueExpr: ExprSyntax, at node: Syntax) {
        if valueExpr.is(BooleanLiteralExprSyntax.self) || valueExpr.is(IntegerLiteralExprSyntax.self) {
            return
        }

        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)

        if let key = stringLiteralValue(keyExpr) {
            if config.allowKeys.contains(key) { return }
            if matchesSecret(key) {
                record(
                    severity: config.severity,
                    message: "Secret written to UserDefaults key '\(key)'. Store secrets in the Keychain, not UserDefaults.",
                    line: location.line,
                    column: location.column)
                return
            }
        }

        if let identifier = valueExpr.as(DeclReferenceExprSyntax.self)?.baseName.text,
           matchesSecret(identifier) {
            record(
                severity: min(config.severity, Diagnostic.Severity.warning),
                message: "Possible secret '\(identifier)' written to UserDefaults. Store secrets in the Keychain.",
                line: location.line,
                column: location.column)
        }
    }

    /// Emits the finding, unless the flagged line carries `// keychain:exempt`
    /// — then the suppression is recorded as a ``DiagnosticOverride`` instead.
    /// Recorded, never silent.
    private func record(severity: Diagnostic.Severity, message: String, line: Int, column: Int) {
        if line >= 1, line <= lines.count, lines[line - 1].contains("// keychain:exempt") {
            overrides.append(DiagnosticOverride(
                ruleId: "keychain-secrets",
                justification: "// keychain:exempt",
                filePath: filePath,
                lineNumber: line))
            return
        }
        findings.append(Diagnostic(
            severity: severity,
            message: message,
            filePath: filePath,
            lineNumber: line,
            columnNumber: column,
            ruleId: "keychain-secrets"))
    }

    // MARK: - Secret matching

    /// True if `name` names a secret: any whole tokenized word is a single-word
    /// secret, or the concatenated normalized form contains a compound secret.
    private func matchesSecret(_ name: String) -> Bool {
        let words = Self.tokenizeWords(name)
        if words.contains(where: { singleWords.contains($0) }) { return true }
        let concatenated = words.joined()
        return compounds.contains(where: { concatenated.contains($0) })
    }

    /// Lowercased alphanumerics only — the substring form for compound matching.
    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Splits an identifier/key into lowercased words on non-alphanumerics and
    /// camelCase boundaries, including acronym→word boundaries (`APIKey` →
    /// `api`, `key`).
    static func tokenizeWords(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(s)

        func flush() {
            if !current.isEmpty { words.append(current.lowercased()); current = "" }
        }

        for index in chars.indices {
            let character = chars[index]
            guard character.isLetter || character.isNumber else { flush(); continue }

            if character.isUppercase, let last = current.last {
                let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
                if last.isLowercase || last.isNumber {
                    flush()                                   // camelCase: fooBar → foo | bar
                } else if last.isUppercase, let following = next, following.isLowercase {
                    flush()                                   // acronym→word: APIKey → API | Key
                }
            }
            current.append(character)
        }
        flush()
        return words
    }

    /// The value of a simple (non-interpolated) string literal, else nil.
    private func stringLiteralValue(_ expr: ExprSyntax) -> String? {
        guard let literal = expr.as(StringLiteralExprSyntax.self) else { return nil }
        var text = ""
        for segment in literal.segments {
            guard let stringSegment = segment.as(StringSegmentSyntax.self) else { return nil }
            text += stringSegment.content.text
        }
        return text
    }
}
