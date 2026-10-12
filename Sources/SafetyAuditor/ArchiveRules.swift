import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Archive extraction (CWE-22, CWE-59)
//
// An archive is a list of claims its author made: this entry is called that, it is a link to
// there. `security.archive-path-escape` reports an entry's name joined onto a destination and
// written without a containment check (zip-slip); `security.archive-symlink` reports a link whose
// target the archive chose, created unchecked, and the switches that turn a library's own check
// off. See `quality-gate-swift-project/plans/proposals/AnArchiveDescribesItself.md` §4.1, §4.2.

/// A loop that walks an archive, found around a join or a link.
struct ArchiveLoop {
    /// The loop statement or iteration closure; its descendants are the iteration.
    let node: Syntax
    /// Names bound to each element (`entry`, `$0`). Empty for a cursor loop, which reads the
    /// current entry through calls rather than binding it.
    let elementNames: [String]
}

/// Whether a joined path is known to be inside its destination before it is written.
enum ContainmentVerdict: Equatable {
    /// A sound check comes first: nothing to report.
    case contained
    /// No check at all, or none that names the joined path.
    case unchecked
    /// Compared by components or a separated prefix, but never standardised: `..` survives.
    case comparedNotStandardised(line: Int)
    /// Standardised, and then never compared with anything.
    case standardisedNotCompared
}

extension SecurityVisitor {

    static let archiveEscapeRule = "security.archive-path-escape"
    static let archiveSymlinkRule = "security.archive-symlink"

    /// Words that make a sequence an archive. Whole camel-case words, not substrings: `target`
    /// is not `tar`. `entries` and `members` are deliberately absent — `MemoryBuilder` writes a
    /// loop over `allEntries` that it generated itself, and the word cannot tell the two apart.
    static let archiveWords: Set<String> = [
        "zip", "archive", "archives", "unarchive", "unzip", "tar", "tarball", "minizip", "cpio",
    ]

    /// C entry points that advance or read a cursor over an archive's entries.
    static let archiveCursorCalls = [
        "unzGoToNextFile", "unzGetCurrentFileInfo", "unzOpenCurrentFile", "unzReadCurrentFile",
        "archive_read_next_header", "mz_zip_",
    ]

    /// Accessors that standardise a path, so `..` no longer survives in it.
    static let standardisers: Set<String> = [
        "standardized", "standardizedFileURL", "resolvingSymlinksInPath", "standardizingPath",
    ]

    // MARK: Path escape

    /// Reports a join whose segment an archive entry chose, written before it is contained.
    func checkArchivePathEscape(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled(Self.archiveEscapeRule), let verdict = archiveEscape(of: node) else { return }
        let location = node.startLocation(converter: converter)
        report(Diagnostic(
            severity: .error,
            message: "An archive entry's name is joined onto a destination and written without a "
                + "containment check. An entry named '../x' or '/x' is written outside the destination. "
                + "\(Self.citation(Self.archiveEscapeRule))\(Self.detail(verdict))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: Self.archiveEscapeRule,
            suggestedFix: "Standardise the joined URL and check it before writing: guard "
                + "out.standardizedFileURL.pathComponents.starts(with: dest.standardizedFileURL.pathComponents) "
                + "else { throw … }, or out.isContained(in: dest), or a function listed in "
                + "security.containmentCheckers."
        ))
    }

    /// Why the join at `join` escapes, or `nil` when it is not an archive join, writes nothing,
    /// or is contained first.
    func archiveEscape(of join: FunctionCallExprSyntax) -> ContainmentVerdict? {
        guard let segment = Self.joinSegment(of: join) else { return nil }
        for loop in Self.archiveLoops(enclosing: join) where Self.derivesFromEntry(segment, in: loop) {
            guard let sink = Self.firstWriteSink(in: loop.node, endingAfter: join.endPosition) else { return nil }
            guard let bound = Self.boundName(of: join) else { return .unchecked }
            let verdict = containmentVerdict(
                subject: bound.name, initialiser: bound.initialiser, before: sink, in: loop.node)
            return verdict == .contained ? nil : verdict
        }
        return nil
    }

    private static func detail(_ verdict: ContainmentVerdict) -> String {
        switch verdict {
        case .contained, .unchecked:
            return ""
        case .comparedNotStandardised(let line):
            return " The containment check on line \(line) compares a path that was never standardised, "
                + "so '..' survives in it and the comparison passes."
        case .standardisedNotCompared:
            return " The joined path is standardised but never compared against the destination."
        }
    }

    /// The segment `call` appends to a directory, for the join spellings the path rules share.
    ///
    /// `appending` only with a path label: `String.appending(_:)` extends a string.
    static func joinSegment(of call: FunctionCallExprSyntax) -> ExprSyntax? {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let first = call.arguments.first {
            let name = member.declName.baseName.text
            let isJoin = name == "appendingPathComponent"
                || (name == "appending" && ["path", "component"].contains(first.label?.text ?? ""))
            return isJoin ? first.expression : nil
        }
        if call.calledExpression.trimmedDescription == "URL",
           call.arguments.contains(where: { $0.label?.text == "relativeTo" }) {
            return call.arguments.first?.expression
        }
        return nil
    }

    // MARK: Symlink

    /// `createSymbolicLink` in an archive loop with a destination the entry chose, unchecked;
    /// and ZIPFoundation's symlink containment switched off, anywhere.
    func checkArchiveSymlink(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled(Self.archiveSymlinkRule) else { return }
        checkSymlinkContainmentOptOut(node)
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "createSymbolicLink",
              let target = node.arguments.first(where: {
                  ["withDestinationURL", "withDestinationPath"].contains($0.label?.text ?? "")
              })?.expression else { return }
        for loop in Self.archiveLoops(enclosing: node) where Self.derivesFromEntry(target, in: loop) {
            var verdict = ContainmentVerdict.unchecked
            if let name = target.as(DeclReferenceExprSyntax.self)?.baseName.text {
                let initialiser = Self.bindingInitialiser(named: name, in: loop.node, before: node.position)
                verdict = containmentVerdict(subject: name, initialiser: initialiser, before: node, in: loop.node)
            }
            guard verdict != .contained else { return }
            reportSymlink(at: Syntax(node), "A symbolic link is created with a target an archive entry chose, "
                + "and the target is not checked against the destination. A link to '/' or '../..' "
                + "lets the next entry write through it. \(Self.citation(Self.archiveSymlinkRule))"
                + Self.detail(verdict))
            return
        }
    }

    /// `symlinksValidWithin: .rootFS` and `allowUncontainedSymlinks: true` switch off the check
    /// ZIPFoundation makes on every link it extracts.
    private func checkSymlinkContainmentOptOut(_ node: FunctionCallExprSyntax) {
        for argument in node.arguments {
            let label = argument.label?.text
            let optsOut = (label == "symlinksValidWithin" && argument.expression.trimmedDescription.hasSuffix("rootFS"))
                || (label == "allowUncontainedSymlinks"
                    && argument.expression.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind == .keyword(.true))
            guard optsOut, let label else { continue }
            reportSymlink(at: Syntax(argument), "'\(label)' lets an extracted symbolic link point anywhere on the "
                + "file system, and the next entry can write through it. "
                + "\(Self.citation(Self.archiveSymlinkRule))")
        }
    }

    private func reportSymlink(at node: Syntax, _ message: String) {
        let location = node.startLocation(converter: converter)
        report(Diagnostic(
            severity: .error,
            message: message,
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: Self.archiveSymlinkRule,
            suggestedFix: "Resolve the link target against the link's directory, standardise it, and check "
                + "it is inside the destination before creating the link; keep ZIPFoundation's default "
                + "symlink containment."
        ))
    }

    // MARK: Command-line extractors

    /// Extractors by executable base name, and the flags that make each keep `/` or `..`.
    ///
    /// Per tool, because the same letter means different things: unzip's `-P` is a password.
    static let unsafeExtractorFlags: [String: Set<String>] = [
        "unzip": ["-:"],
        "tar": ["-P", "--absolute-paths", "--insecure", "--absolute-names"],
    ]

    static func extractorName(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if name == "unzip" { return "unzip" }
        return ["tar", "bsdtar", "gtar", "gnutar"].contains(name) ? "tar" : nil
    }

    /// Records `x.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")` and its tar sibling.
    func noteExtractorAssignment(_ node: SequenceExprSyntax) {
        guard let (base, path) = Self.executableAssignment(node), let tool = Self.extractorName(path) else { return }
        extractorVariables[base] = tool
    }

    /// `x.arguments = [...]` handing an extractor a flag that keeps `../` or a leading `/`.
    func checkExtractorFlags(_ node: SequenceExprSyntax) {
        guard isRuleEnabled(Self.archiveEscapeRule),
              let (base, array) = Self.argumentsAssignment(node) else { return }
        let items = Array(array.elements)
        let first = items.first?.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        guard let tool = extractorVariables[base] ?? first.flatMap(Self.extractorName),
              let unsafe = Self.unsafeExtractorFlags[tool] else { return }
        for item in items {
            guard let flag = item.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue,
                  unsafe.contains(flag) else { continue }
            let location = item.startLocation(converter: converter)
            report(Diagnostic(
                severity: .error,
                message: "\(tool) is given \(flag), which keeps '..' or a leading '/' in entry names, so an "
                    + "archive can write outside the destination. \(Self.citation(Self.archiveEscapeRule))",
                filePath: fileName,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: Self.archiveEscapeRule,
                suggestedFix: "Remove \(flag); \(tool) strips '..' and leading '/' by default."
            ))
            return
        }
    }

    /// `x.arguments = [ … ]`: the variable and the array.
    static func argumentsAssignment(_ node: SequenceExprSyntax) -> (String, ArrayExprSyntax)? {
        let elements = Array(node.elements)
        guard elements.count >= 3,
              elements[1].is(AssignmentExprSyntax.self),
              let member = elements[0].as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "arguments",
              let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
              let array = elements[2].as(ArrayExprSyntax.self) else { return nil }
        return (base, array)
    }

    // MARK: Finding the loop

    /// Every loop around `node`, innermost first, that walks an archive — stopping at the
    /// enclosing declaration.
    static func archiveLoops(enclosing node: some SyntaxProtocol) -> [ArchiveLoop] {
        var loops: [ArchiveLoop] = []
        var current = node.parent
        while let candidate = current {
            if candidate.is(FunctionDeclSyntax.self) || candidate.is(InitializerDeclSyntax.self)
                || candidate.is(AccessorDeclSyntax.self) { break }
            if let loop = archiveLoop(candidate, around: node) { loops.append(loop) }
            current = candidate.parent
        }
        return loops
    }

    private static func archiveLoop(_ candidate: Syntax, around node: some SyntaxProtocol) -> ArchiveLoop? {
        if let loop = candidate.as(ForStmtSyntax.self), contains(loop.body, node) {
            let evidence = sequenceIdentifiers(loop.sequence, before: loop)
                + (loop.typeAnnotation.map { identifiers(in: $0) } ?? [])
            guard hasArchiveVocabulary(evidence) else { return nil }
            return ArchiveLoop(node: candidate, elementNames: boundNames(loop.pattern))
        }
        if let closure = candidate.as(ClosureExprSyntax.self),
           let sequence = iteratedSequence(of: closure),
           hasArchiveVocabulary(sequenceIdentifiers(sequence, before: closure)) {
            return ArchiveLoop(node: candidate, elementNames: closureParameters(closure))
        }
        if candidate.is(WhileStmtSyntax.self) || candidate.is(RepeatStmtSyntax.self),
           readsArchiveCursor(candidate) {
            return ArchiveLoop(node: candidate, elementNames: [])
        }
        return nil
    }

    private static func contains(_ outer: some SyntaxProtocol, _ inner: some SyntaxProtocol) -> Bool {
        outer.position <= inner.position && inner.endPosition <= outer.endPosition
    }

    /// The identifiers that describe a sequence: its own, plus those of the declaration of the
    /// name it starts from when that is visible — `let parts = try ZIPReader.read(from: d)` or a
    /// parameter `_ entries: [ZIPEntry]`. Identifiers only: `"05_99_ARCHIVE"` in a list of
    /// directory names is data, and it made twenty copies of a setup script look like extractors.
    private static func sequenceIdentifiers(_ sequence: ExprSyntax, before node: some SyntaxProtocol) -> [String] {
        var names = identifiers(in: sequence)
        guard let root = sequence.firstToken(viewMode: .sourceAccurate),
              case .identifier = root.tokenKind else { return names }
        if let body = enclosingBody(of: node),
           let binding = bindings(named: root.text, in: body, before: node.position).last {
            names += identifiers(in: binding)
        }
        if let parameter = parameterType(named: root.text, around: node) { names += identifiers(in: parameter) }
        return names
    }

    private static func identifiers(in node: some SyntaxProtocol) -> [String] {
        node.tokens(viewMode: .sourceAccurate).compactMap { token in
            if case .identifier = token.tokenKind { return token.text }
            return nil
        }
    }

    /// Whether any identifier contains an archive word as a whole camel-case or snake-case word.
    static func hasArchiveVocabulary(_ identifiers: [String]) -> Bool {
        identifiers.flatMap { camelCaseWords($0) }.contains { archiveWords.contains($0) }
    }

    /// `seq` in `seq.forEach { … }` / `seq.map { … }`.
    private static func iteratedSequence(of closure: ClosureExprSyntax) -> ExprSyntax? {
        var call = closure.parent?.as(FunctionCallExprSyntax.self)
        if call == nil { call = closure.parent?.parent?.parent?.as(FunctionCallExprSyntax.self) }
        guard let member = call?.calledExpression.as(MemberAccessExprSyntax.self),
              ["forEach", "map", "compactMap", "flatMap"].contains(member.declName.baseName.text) else { return nil }
        return member.base
    }

    private static func closureParameters(_ closure: ClosureExprSyntax) -> [String] {
        guard let clause = closure.signature?.parameterClause else { return ["$0"] }
        if let shorthand = clause.as(ClosureShorthandParameterListSyntax.self) {
            return shorthand.map(\.name.text)
        }
        if let full = clause.as(ClosureParameterClauseSyntax.self) {
            return full.parameters.map { ($0.secondName ?? $0.firstName).text }
        }
        return []
    }

    private static func boundNames(_ pattern: PatternSyntax) -> [String] {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) { return [identifier.identifier.text] }
        if let tuple = pattern.as(TuplePatternSyntax.self) { return tuple.elements.flatMap { boundNames($0.pattern) } }
        if let binding = pattern.as(ValueBindingPatternSyntax.self) { return boundNames(binding.pattern) }
        return []
    }

    /// A `while` / `repeat` whose body calls a C entry point that walks an archive (minizip,
    /// libarchive), or a function whose name says it does.
    private static func readsArchiveCursor(_ loop: Syntax) -> Bool {
        CallCollector.calls(in: loop).contains { call in
            let callee = call.calledExpression.trimmedDescription
            let name = callee.split(separator: ".").last.map(String.init) ?? callee
            return archiveCursorCalls.contains { name.hasPrefix($0) } || hasArchiveVocabulary([name])
        }
    }

    // MARK: Provenance

    /// Whether `expression` carries a name the archive chose: it mentions the loop's element, or
    /// — for a cursor loop — a value read inside the loop, directly or through local bindings.
    static func derivesFromEntry(_ expression: ExprSyntax, in loop: ArchiveLoop, depth: Int = 0) -> Bool {
        guard depth < 4, isChosenSegment(expression, at: expression) else { return false }
        let names = referencedNames(in: expression)
        if names.contains(where: loop.elementNames.contains) { return true }
        for name in names {
            guard let value = bindingInitialiser(named: name, in: loop.node, before: expression.position) else { continue }
            if loop.elementNames.isEmpty || derivesFromEntry(value, in: loop, depth: depth + 1) { return true }
        }
        return false
    }

    /// Identifiers `expression` reads, not counting member names: `entry` in `entry.path`.
    private static func referencedNames(in expression: some SyntaxProtocol) -> [String] {
        expression.tokens(viewMode: .sourceAccurate).compactMap { token in
            guard let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { return nil }
            if let member = reference.parent?.as(MemberAccessExprSyntax.self),
               member.declName.id == reference.id { return nil }
            return token.text
        }
    }

    /// The initialiser of the last `let` / `var` binding `name` inside `scope` before `position`.
    static func bindingInitialiser(named name: String, in scope: Syntax, before position: AbsolutePosition) -> ExprSyntax? {
        bindings(named: name, in: scope, before: position).last?.initializer?.value
    }

    private static func bindings(named name: String, in scope: Syntax, before position: AbsolutePosition) -> [PatternBindingSyntax] {
        scope.tokens(viewMode: .sourceAccurate)
            .compactMap { $0.parent?.as(IdentifierPatternSyntax.self) }
            .filter { $0.identifier.text == name && $0.position < position }
            .compactMap { $0.parent?.as(PatternBindingSyntax.self) }
    }

    /// The written type of a parameter `name` of the enclosing function, if it has one.
    private static func parameterType(named name: String, around node: some SyntaxProtocol) -> TypeSyntax? {
        var current = node.parent
        while let candidate = current {
            if let function = candidate.as(FunctionDeclSyntax.self) {
                return function.signature.parameterClause.parameters
                    .first { ($0.secondName ?? $0.firstName).text == name }?.type
            }
            current = candidate.parent
        }
        return nil
    }

    // MARK: Sinks

    /// The first call in `scope` that writes to disk and ends after `position`.
    static func firstWriteSink(in scope: Syntax, endingAfter position: AbsolutePosition) -> FunctionCallExprSyntax? {
        CallCollector.calls(in: scope).first { $0.endPosition > position && isWriteSink($0) }
    }

    private static let writingMembers: Set<String> = [
        "createFile", "createDirectory", "copyItem", "moveItem", "createSymbolicLink", "linkItem", "extract",
    ]

    static func isWriteSink(_ call: FunctionCallExprSyntax) -> Bool {
        let firstLabel = call.arguments.first?.label?.text ?? ""
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if name == "write" { return ["to", "toFile"].contains(firstLabel) }
            return writingMembers.contains(name)
        }
        switch call.calledExpression.trimmedDescription {
        case "FileHandle":
            return firstLabel.hasPrefix("forWriting") || firstLabel.hasPrefix("forUpdating")
        case "fopen":
            let mode = call.arguments.dropFirst().first?.expression
                .as(StringLiteralExprSyntax.self)?.representedLiteralValue ?? ""
            return mode.contains("w") || mode.contains("a") || mode.contains("+")
        default:
            return false
        }
    }

    // MARK: Containment

    /// `let out = <join>[.accessors]`: the name the joined path is bound to, and its initialiser.
    static func boundName(of join: FunctionCallExprSyntax) -> (name: String, initialiser: ExprSyntax)? {
        var current = Syntax(join)
        while let parent = current.parent {
            if let member = parent.as(MemberAccessExprSyntax.self), member.base?.id == current.id {
                current = parent
            } else if let call = parent.as(FunctionCallExprSyntax.self), call.calledExpression.id == current.id,
                      call.arguments.isEmpty {
                current = parent
            } else {
                break
            }
        }
        guard let binding = current.parent?.parent?.as(PatternBindingSyntax.self),
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let value = binding.initializer?.value else { return nil }
        return (name, value)
    }

    /// Whether `subject` is checked soundly for containment before `sink`.
    ///
    /// `isContained(in:)` and a configured checker standardise by contract. A component or
    /// separated-prefix comparison counts only on a standardised path — `a/b/../../etc` has
    /// components that start with `a`. A check counts if it is a `guard`, an `if` that leaves
    /// the iteration, or an `if` the sink sits inside.
    func containmentVerdict(
        subject: String, initialiser: ExprSyntax?, before sink: some SyntaxProtocol, in scope: Syntax
    ) -> ContainmentVerdict {
        let checks = ContainmentCheckCollector.checks(in: scope, before: sink, checkers: configuration.containmentCheckers)
        if checks.checkerCalls.contains(where: { Self.mentions($0, subject) }) { return .contained }
        let standardisedAtBinding = initialiser.map(Self.endsStandardised) ?? false
        var unstandardisedLine: Int?
        for check in checks.conditions where Self.mentions(check.text, subject) {
            if check.text.contains(".isContained(in:")
                || configuration.containmentCheckers.contains(where: { check.text.contains($0 + "(") }) {
                return .contained
            }
            guard check.text.contains("pathComponents.starts(with:") || Self.hasSeparatedPrefixTest(check.text) else { continue }
            let standardisedHere = Self.standardisers.contains { check.text.contains("\(subject).\($0)") }
            if standardisedAtBinding || standardisedHere { return .contained }
            unstandardisedLine = unstandardisedLine ?? check.position.map { converter.location(for: $0).line }
        }
        if let line = unstandardisedLine { return .comparedNotStandardised(line: line) }
        return standardisedAtBinding ? .standardisedNotCompared : .unchecked
    }

    /// Whether `expression` ends in a chain of path accessors that includes a standardiser.
    static func endsStandardised(_ expression: ExprSyntax) -> Bool {
        var current = expression
        for _ in 0..<8 {
            var name: String?
            var base: ExprSyntax?
            if let call = current.as(FunctionCallExprSyntax.self), call.arguments.isEmpty,
               let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                name = member.declName.baseName.text
                base = member.base
            } else if let member = current.as(MemberAccessExprSyntax.self) {
                name = member.declName.baseName.text
                base = member.base
            }
            guard let name, let base else { return false }
            if standardisers.contains(name) { return true }
            current = base
        }
        return false
    }

    /// Whether `text` names `identifier` as a whole word.
    static func mentions(_ text: String, _ identifier: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9_$])" + NSRegularExpression.escapedPattern(for: identifier) + "(?![A-Za-z0-9_])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Every function call under a node, in source order.
final class CallCollector: SyntaxVisitor {
    private(set) var calls: [FunctionCallExprSyntax] = []

    static func calls(in node: some SyntaxProtocol) -> [FunctionCallExprSyntax] {
        let collector = CallCollector(viewMode: .sourceAccurate)
        collector.walk(node)
        return collector.calls
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        calls.append(node)
        return .visitChildren
    }
}

/// Containment decisions before a sink: conditions that hold at the sink, and statement calls to
/// configured checkers (which throw rather than return false).
final class ContainmentCheckCollector: SyntaxVisitor {
    struct Condition {
        let text: String
        let position: AbsolutePosition?
    }

    private let sinkStart: AbsolutePosition
    private let sinkEnd: AbsolutePosition
    private let checkers: [String]
    private(set) var conditions: [Condition] = []
    private(set) var checkerCalls: [String] = []

    private init(sink: some SyntaxProtocol, checkers: [String]) {
        self.sinkStart = sink.position
        self.sinkEnd = sink.endPosition
        self.checkers = checkers
        super.init(viewMode: .sourceAccurate)
    }

    static func checks(
        in scope: Syntax, before sink: some SyntaxProtocol, checkers: [String]
    ) -> ContainmentCheckCollector {
        let collector = ContainmentCheckCollector(sink: sink, checkers: checkers)
        collector.walk(scope)
        return collector
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.endPosition <= sinkStart { record(node.conditions) }
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.position < sinkStart else { return .visitChildren }
        let sinkInside = node.body.position <= sinkStart && sinkEnd <= node.body.endPosition
        let condition = node.conditions.trimmedDescription
        if (sinkInside && !condition.hasPrefix("!")) || (node.endPosition <= sinkStart && Self.exits(node.body)) {
            record(node.conditions)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if node.endPosition <= sinkStart, checkers.contains(node.calledExpression.trimmedDescription) {
            checkerCalls.append(node.trimmedDescription)
        }
        return .visitChildren
    }

    private func record(_ conditions: ConditionElementListSyntax) {
        self.conditions.append(Condition(text: conditions.trimmedDescription, position: conditions.position))
    }

    /// Whether a block leaves the iteration: `continue`, `break`, `return` or `throw`.
    private static func exits(_ block: CodeBlockSyntax) -> Bool {
        block.tokens(viewMode: .sourceAccurate).contains {
            [.keyword(.continue), .keyword(.break), .keyword(.return), .keyword(.throw)].contains($0.tokenKind)
        }
    }
}
