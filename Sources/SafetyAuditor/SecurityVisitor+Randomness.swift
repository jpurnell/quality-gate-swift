import Foundation
import QualityGateCore
import SwiftSyntax

/// What the randomness rules examined in one file, or a run — the `security.randomness-coverage`
/// note (`ASeedIsNotASecret.md` §3.8).
struct RandomnessSiteCounts: Sendable, Equatable {
    /// Security-named values that draw on a generator, the clock, the process or a UUID.
    var examined = 0
    /// Of those, made only from a safe source.
    var safe = 0
    /// Reported by `security.weak-prng`.
    var weak = 0
    /// Reported by `security.predictable-token`.
    var predictable = 0
    /// Reported by `security.uuid-as-secret`.
    var uuid = 0
    /// Drawn from a generator whose origin this file cannot show: a parameter, a stored
    /// property, a custom type with an innocent name. Counted, not judged.
    var unresolvedGenerator = 0
    /// Credential-producing functions that accept their caller's generator — the seams.
    var generatorSeams = 0

    /// Adds another file's counts to these.
    mutating func add(_ other: RandomnessSiteCounts) {
        examined += other.examined
        safe += other.safe
        weak += other.weak
        predictable += other.predictable
        uuid += other.uuid
        unresolvedGenerator += other.unresolvedGenerator
        generatorSeams += other.generatorSeams
    }
}

/// A source of a value's bits, as far as the randomness rules care.
enum RandomnessSource: Equatable {
    /// A non-cryptographic generator: the C family or GameplayKit.
    case weak(String)
    /// Something an attacker can observe: the clock, the pid, a per-process hash. `isTime` is
    /// true for the clock, which is a time until it is converted into something else.
    case predictable(String, isTime: Bool)
    /// `UUID()` / `NSUUID()`.
    case uuid
    /// A cryptographically secure source.
    case safe(String)
    /// A draw from the generator `generator` — `using: &generator` or `generator.next()`.
    case generatorDraw(generator: ExprSyntax)

    /// The C generators `security.weak-prng` names. `random` counts only with no arguments and
    /// no receiver — `T.random(in:)` is the standard library's, and is safe.
    static let weakFunctions: Set<String> = [
        "rand", "random", "drand48", "erand48", "lrand48", "nrand48", "mrand48", "jrand48", "rand_r",
    ]

    /// GameplayKit's sources and distributions — *"not cryptographically robust"*, Apple's words.
    static let gameplayKitTypes: Set<String> = [
        "GKRandomSource", "GKARC4RandomSource", "GKLinearCongruentialRandomSource",
        "GKMersenneTwisterRandomSource", "GKRandomDistribution", "GKGaussianDistribution",
        "GKShuffledDistribution",
    ]

    /// Free functions whose result is observable state.
    static let predictableFunctions: [String: Bool] = [
        "CFAbsoluteTimeGetCurrent": true, "mach_absolute_time": true, "mach_continuous_time": true,
        "getpid": false, "ObjectIdentifier": false,
    ]

    /// Members whose value is observable state, on any receiver.
    static let predictableMembers: [String: Bool] = [
        "timeIntervalSince1970": true, "timeIntervalSinceReferenceDate": true, "systemUptime": true,
        "processIdentifier": false, "hashValue": false,
    ]

    /// Types whose `.now` is the clock.
    static let clockTypes: Set<String> = ["Date", "NSDate", "ContinuousClock", "SuspendingClock", "DispatchTime", "DispatchWallTime"]

    /// Free functions and initialisers that are secure sources.
    static let safeCallees: Set<String> = [
        "SystemRandomNumberGenerator", "SecRandomCopyBytes", "CCRandomGenerateBytes", "arc4random",
        "arc4random_uniform", "arc4random_buf", "getentropy", "getrandom", "SymmetricKey",
    ]

    /// What `node` is, if it is a source at all.
    static func classify(_ node: Syntax) -> RandomnessSource? {
        if let call = node.as(FunctionCallExprSyntax.self) { return classify(call) }
        if let reference = node.as(DeclReferenceExprSyntax.self),
           gameplayKitTypes.contains(reference.baseName.text) {
            return .weak(reference.baseName.text)
        }
        if let member = node.as(MemberAccessExprSyntax.self) { return classify(member) }
        return nil
    }

    private static func classify(_ call: FunctionCallExprSyntax) -> RandomnessSource? {
        if let generator = call.arguments.first(where: { $0.label?.text == "using" })?
            .expression.as(InOutExprSyntax.self)?.expression {
            return .generatorDraw(generator: generator)
        }
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return classifyFreeCall(reference.baseName.text, call: call)
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return nil }
        let name = member.declName.baseName.text
        let receiver = member.base?.trimmedDescription ?? ""
        switch name {
        case "random" where member.base != nil:
            return .safe(".random")
        case "now" where clockTypes.contains(receiver):
            return .predictable("\(receiver).now()", isTime: true)
        case "Nonce" where call.arguments.isEmpty:
            return .safe(member.trimmedDescription)
        case "PrivateKey" where call.arguments.isEmpty:
            return .safe(member.trimmedDescription)
        case "next" where call.arguments.isEmpty:
            return member.base.map { .generatorDraw(generator: $0) }
        case "finalize" where call.arguments.isEmpty:
            guard let base = member.base,
                  let reference = base.as(DeclReferenceExprSyntax.self),
                  let initialiser = SecurityValueSite.localInitialiser(named: reference.baseName.text, before: Syntax(call)),
                  initialiser.as(FunctionCallExprSyntax.self)?.calledExpression.trimmedDescription == "Hasher" else {
                return nil
            }
            return .predictable("Hasher", isTime: false)
        default:
            return nil
        }
    }

    private static func classifyFreeCall(_ name: String, call: FunctionCallExprSyntax) -> RandomnessSource? {
        if weakFunctions.contains(name) {
            return name == "random" && !call.arguments.isEmpty ? nil : .weak(name)
        }
        if let isTime = predictableFunctions[name] { return .predictable("\(name)()", isTime: isTime) }
        if (name == "Date" || name == "NSDate") && call.arguments.isEmpty { return .predictable("\(name)()", isTime: true) }
        if (name == "UUID" || name == "NSUUID") && call.arguments.isEmpty { return .uuid }
        if safeCallees.contains(name) { return .safe(name) }
        return nil
    }

    private static func classify(_ member: MemberAccessExprSyntax) -> RandomnessSource? {
        // A member called as a method is classified at its call.
        if let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id {
            return nil
        }
        let name = member.declName.baseName.text
        if let isTime = predictableMembers[name], member.base != nil { return .predictable(".\(name)", isTime: isTime) }
        if name == "now", let receiver = member.base?.trimmedDescription, clockTypes.contains(receiver) {
            return .predictable("\(receiver).now", isTime: true)
        }
        return nil
    }

    /// The name a diagnostic gives the source.
    var displayName: String {
        switch self {
        case .weak(let name), .safe(let name): name
        case .predictable(let name, _): name
        case .uuid: "UUID()"
        case .generatorDraw(let generator): generator.trimmedDescription
        }
    }
}

/// Where a generator drawn in a security context came from.
enum GeneratorOrigin: Equatable {
    /// `SystemRandomNumberGenerator()` bound in this function.
    case safe
    /// A seeded or deterministic generator bound in this function.
    case seeded(cwe: String, reason: String)
    /// A parameter, a stored property, an existential, a type with an innocent name.
    case unresolved
}

/// A value is unpredictable or it is not (`ASeedIsNotASecret.md`).
///
/// Four rules, one question each, all asked only of a value in a security context as
/// `SecurityContext` defines it and ``SecurityValueSite`` reads it off the tree:
///
/// | Rule | Severity | CWE | The value is made by |
/// |---|---|---|---|
/// | `security.weak-prng` | error | 338 | the C generators or GameplayKit |
/// | `security.seeded-secret` | error | 336 literal seed, 337 clock/pid seed, 335 otherwise | a generator seeded in the same function |
/// | `security.predictable-token` | error | 341 | only literals and the clock, the pid, `hashValue`, `Hasher`, `ObjectIdentifier` |
/// | `security.uuid-as-secret` | warning | 340 | only literals and `UUID()` |
///
/// One value, one finding: a seeded GameplayKit source is `weak-prng`, not also
/// `seeded-secret`, and a C generator after `srand` is `weak-prng` too.
extension SecurityVisitor {

    static let weakPRNGRuleID = "security.weak-prng"
    static let seededRuleID = "security.seeded-secret"
    static let predictableRuleID = "security.predictable-token"
    static let uuidRuleID = "security.uuid-as-secret"

    static var randomnessRules: [String] {
        [weakPRNGRuleID, seededRuleID, predictableRuleID, uuidRuleID]
    }

    /// Words in a generator's type name that make it deterministic by construction.
    static let seededGeneratorWords: Set<String> = [
        "seeded", "splitmix", "xoshiro", "xorshift", "pcg", "lcg", "mersenne", "twister",
        "congruential", "deterministic", "fixed", "mock", "fake", "stub",
    ]

    /// Argument labels that hand a generator its seed.
    static let seedLabels: Set<String> = ["seed", "state", "seeds"]

    /// Identifiers that make a seed the clock or the process.
    static let observableSeedNames: Set<String> = [
        "Date", "now", "timeIntervalSince1970", "timeIntervalSinceReferenceDate", "CFAbsoluteTimeGetCurrent",
        "mach_absolute_time", "getpid", "processIdentifier", "DispatchTime", "uptimeNanoseconds",
        "ContinuousClock", "SuspendingClock", "time",
    ]

    /// Runs the four randomness rules over `file`, and counts what they examined.
    func checkRandomness(in file: SourceFileSyntax) {
        guard Self.randomnessRules.contains(where: isRuleEnabled) else { return }
        let collector = RandomnessCollector()
        collector.walk(file)
        randomnessSites.generatorSeams += collector.generatorSeams

        var order: [SyntaxIdentifier] = []
        var groups: [SyntaxIdentifier: RandomnessGroup] = [:]
        for node in collector.candidates {
            guard let source = RandomnessSource.classify(node),
                  let resolution = SecurityValueSite.resolve(node) else { continue }
            let key = resolution.root.id
            if groups[key] == nil {
                order.append(key)
                groups[key] = RandomnessGroup(resolution: resolution)
            }
            groups[key]?.sources.append((node, source))
        }
        for key in order {
            if let group = groups[key] { judge(group) }
        }
    }

    /// Reports at most one finding per rule for one value, and counts it.
    private func judge(_ group: RandomnessGroup) {
        randomnessSites.examined += 1
        let subject = Self.describe(group.resolution)

        if let (node, source) = group.sources.first(where: { if case .weak = $0.1 { true } else { false } }) {
            randomnessSites.weak += 1
            reportRandomness(node, ruleId: Self.weakPRNGRuleID, message:
                "'\(source.displayName)' is not a cryptographic generator, and its output becomes \(subject). "
                + "Seen a few outputs, the rest can be predicted. \(Self.citation(Self.weakPRNGRuleID))")
            return
        }

        var unresolved = false
        for (node, source) in group.sources {
            guard case .generatorDraw(let generator) = source else { continue }
            switch generatorOrigin(generator, at: node) {
            case .safe:
                continue
            case .unresolved:
                unresolved = true
            case .seeded where isTestFile:
                // A test pins a credential's bytes by seeding: `ASeedIsNotASecret.md` §8.
                continue
            case .seeded(let cwe, let reason):
                reportRandomness(node, ruleId: Self.seededRuleID, message:
                    "'\(generator.trimmedDescription)' \(reason), so \(subject) can be reproduced by anyone who "
                    + "knows the seed. [\(cwe)]")
                return
            }
        }
        if unresolved { randomnessSites.unresolvedGenerator += 1 }

        if judgeComposition(group, subject: subject) || unresolved { return }
        // What is left drew on a safe source — a secure call, or a generator bound to
        // `SystemRandomNumberGenerator()` here — or on nothing a rule judges (a bare time).
        let drewSafely = group.sources.contains { source in
            switch source.1 {
            case .safe, .generatorDraw: true
            case .weak, .predictable, .uuid: false
            }
        }
        if drewSafely { randomnessSites.safe += 1 }
    }

    /// `predictable-token` and `uuid-as-secret`: what the whole value is made of.
    private func judgeComposition(_ group: RandomnessGroup, subject: String) -> Bool {
        let parts = SecurityValueSite.valueParts(of: group.resolution.root)
        let leaves = parts.flatMap { part in
            SecurityValueSite.leaves(of: part) { RandomnessSource.classify($0) != nil || Self.isLiteral($0) }
        }
        var predictable: [String] = []
        var onlyTime = true
        var hasUUID = false
        for leaf in leaves {
            if Self.isLiteral(leaf) { continue }
            switch RandomnessSource.classify(leaf) {
            case .predictable(let name, let isTime):
                predictable.append(name)
                onlyTime = onlyTime && isTime
            case .uuid:
                hasUUID = true
            default:
                return false
            }
        }

        if hasUUID, let (node, _) = group.sources.first(where: { $0.1 == .uuid }) {
            randomnessSites.uuid += 1
            // A test's session id opens nothing.
            guard isRuleEnabled(Self.uuidRuleID), !isTestFile else { return true }
            let location = node.startLocation(converter: converter)
            reportUnderCryptoPolicy(Diagnostic(
                severity: .warning,
                message: "\(subject) is a UUID. RFC 9562 says a UUID MUST NOT be used as a security "
                    + "capability, and Foundation's UUID becomes time-based where CFUUIDVersionNumber=1. "
                    + "\(Self.citation(Self.uuidRuleID))",
                filePath: fileName,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: Self.uuidRuleID,
                suggestedFix: "Draw 32 bytes from SystemRandomNumberGenerator and hex- or base64-encode them; "
                    + "or, if the id authorises nothing by itself, say so where a reviewer reads it."))
            return true
        }

        // The clock is a time, not a token, until it is turned into something else — a string,
        // an integer, an encoding. `Date()`, `now - start` and `sessionStart = start` are times
        // and durations; HRVKit's training *session* measured exactly these.
        let converted = parts.contains { Self.convertsToRepresentation($0) }
        guard !predictable.isEmpty, !(onlyTime && !converted),
              let (node, _) = group.sources.first(where: { if case .predictable = $0.1 { true } else { false } }) else {
            return false
        }
        randomnessSites.predictable += 1
        let names = Array(NSOrderedSet(array: predictable)).compactMap { $0 as? String }
        reportRandomness(node, ruleId: Self.predictableRuleID, message:
            "\(subject) is made only of \(names.map { "'\($0)'" }.joined(separator: ", ")) — state an "
            + "attacker can observe or guess. A hashValue is a constant function of its input for the "
            + "life of the process. \(Self.citation(Self.predictableRuleID))")
        return true
    }

    /// Whether a value turns what it is made of into a representation: string interpolation,
    /// a conversion (`String(…)`, `Int(…)`), or an encoding member — followed into locals the
    /// way ``SecurityValueSite/leaves(of:depth:isLeaf:)`` follows them.
    static func convertsToRepresentation(_ node: Syntax, depth: Int = SecurityValueSite.maximumHops) -> Bool {
        let encoders: Set<String> = [
            "description", "debugDescription", "base64EncodedString", "base64EncodedData",
            "base64URLEncodedString", "hexString", "hexEncoded", "hexEncodedString", "hexDigest", "data",
        ]
        for descendant in [node] + Array(node.children(viewMode: .sourceAccurate)) {
            if let literal = descendant.as(StringLiteralExprSyntax.self),
               literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) { return true }
            // `Date()` is spelled like a conversion and converts nothing: it needs an argument.
            if let call = descendant.as(FunctionCallExprSyntax.self), SecurityValueSite.isConversion(call),
               !call.arguments.isEmpty {
                return true
            }
            if let member = descendant.as(MemberAccessExprSyntax.self), encoders.contains(member.declName.baseName.text) {
                return true
            }
            if descendant.id != node.id, convertsToRepresentation(descendant, depth: depth) { return true }
            if let reference = descendant.as(DeclReferenceExprSyntax.self), depth > 0,
               let initialiser = SecurityValueSite.localInitialiser(named: reference.baseName.text, before: descendant),
               convertsToRepresentation(Syntax(initialiser), depth: depth - 1) {
                return true
            }
        }
        return false
    }

    /// Whether this file is test code, by the path convention every checker here uses.
    var isTestFile: Bool {
        fileName.contains("/Tests/") || fileName.hasPrefix("Tests/")
    }

    /// Reports one randomness finding through ``report(_:)``.
    private func reportRandomness(_ node: Syntax, ruleId: String, message: String) {
        guard isRuleEnabled(ruleId) else { return }
        let location = node.startLocation(converter: converter)
        report(Diagnostic(
            severity: .error,
            message: message,
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: ruleId,
            suggestedFix: "Bind `var generator = SystemRandomNumberGenerator()` in this function and draw with "
                + "`using: &generator`, or use SecRandomCopyBytes or CryptoKit's SymmetricKey(size:). Keep "
                + "seeded generators for simulations and tests."))
    }

    /// Where the generator `expression` drawn at `node` was bound.
    func generatorOrigin(_ expression: ExprSyntax, at node: Syntax) -> GeneratorOrigin {
        guard let reference = expression.as(DeclReferenceExprSyntax.self),
              let initialiser = SecurityValueSite.localInitialiser(named: reference.baseName.text, before: node),
              let call = initialiser.as(FunctionCallExprSyntax.self) else { return .unresolved }
        let typeText = call.calledExpression.trimmedDescription
        let typeName = String(typeText.split(separator: "<").first ?? "")
            .split(separator: ".").last.map(String.init) ?? typeText
        if typeName == "SystemRandomNumberGenerator" { return .safe }

        let arguments = Array(call.arguments)
        let seed = arguments.first { $0.label.map { Self.seedLabels.contains($0.text) } ?? false }
            ?? arguments.first { $0.label == nil && $0.expression.is(IntegerLiteralExprSyntax.self) }
        let deterministicName = Self.deterministicWord(in: typeName)
        guard seed != nil || deterministicName != nil else { return .unresolved }

        guard let seed else {
            return .seeded(cwe: "CWE-335", reason: "is a '\(typeName)', deterministic by name")
        }
        if Self.isLiteralSeed(seed.expression) {
            return .seeded(cwe: "CWE-336", reason: "is seeded with the literal \(seed.expression.trimmedDescription)")
        }
        let names = Set(seed.expression.tokens(viewMode: .sourceAccurate).map(\.text))
        if !names.isDisjoint(with: Self.observableSeedNames) {
            return .seeded(cwe: "CWE-337", reason: "is seeded from the clock or the process")
        }
        return .seeded(cwe: "CWE-335", reason: "is seeded in this function")
    }

    /// A seeded-generator word in a type name, matched over runs of whole words: `SplitMix64` is
    /// `split` `mix` `64`, and `splitmix` is the run.
    static func deterministicWord(in typeName: String) -> String? {
        let words = SensitiveName.words(typeName)
        for start in words.indices {
            var run = ""
            for end in start..<min(start + 3, words.count) {
                run += words[end]
                if seededGeneratorWords.contains(run) { return run }
            }
        }
        return nil
    }

    /// An integer or string literal, possibly negated or converted: `42`, `"x"`, `UInt64(42)`.
    static func isLiteralSeed(_ expression: ExprSyntax) -> Bool {
        if expression.is(IntegerLiteralExprSyntax.self) { return true }
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return !literal.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self) { return isLiteralSeed(prefix.expression) }
        if let call = expression.as(FunctionCallExprSyntax.self), SecurityValueSite.isConversion(call),
           call.arguments.count == 1, let only = call.arguments.first {
            return isLiteralSeed(only.expression)
        }
        return false
    }

    /// A literal that adds no bits: a number, a plain string, a Boolean, `nil`, `.max`.
    static func isLiteral(_ node: Syntax) -> Bool {
        if node.is(IntegerLiteralExprSyntax.self) || node.is(FloatLiteralExprSyntax.self)
            || node.is(BooleanLiteralExprSyntax.self) || node.is(NilLiteralExprSyntax.self) {
            return true
        }
        if let literal = node.as(StringLiteralExprSyntax.self) {
            return !literal.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
        }
        if let member = node.as(MemberAccessExprSyntax.self) { return member.base == nil }
        return false
    }

    /// "'token'", "the return value of 'makeToken'", "an HTTP header value" — and the locals on the way.
    static func describe(_ resolution: SecurityValueSite.Resolution) -> String {
        var text: String
        switch resolution.site.destination {
        case .binding(let name): text = "'\(name)'"
        case .argument(let label): text = "the '\(label):' argument"
        case .returned(let function): text = "the return value of '\(function)'"
        case .sink(.httpHeader): text = "an HTTP header value"
        case .sink(.cookie): text = "a cookie"
        case .sink(.urlQuery): text = "a URL query value"
        }
        if case .weakNameInSecurityScope(_, let scope) = resolution.verdict {
            text += " in '\(scope)'"
        }
        if !resolution.via.isEmpty {
            text += " (through \(resolution.via.map { "'\($0)'" }.joined(separator: ", ")))"
        }
        return text
    }
}

/// One value in a security context and every source found in it.
struct RandomnessGroup {
    let resolution: SecurityValueSite.Resolution
    var sources: [(Syntax, RandomnessSource)] = []
}

/// Collects candidate source nodes and counts generator seams, in source order.
final class RandomnessCollector: SyntaxVisitor {
    private(set) var candidates: [Syntax] = []
    private(set) var generatorSeams = 0

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        candidates.append(Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if RandomnessSource.gameplayKitTypes.contains(node.baseName.text) { candidates.append(Syntax(node)) }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.declName.baseName.text
        if RandomnessSource.predictableMembers[name] != nil || name == "now" { candidates.append(Syntax(node)) }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.takesGenerator(node.signature, generics: node.genericParameterClause, where: node.genericWhereClause) {
            let names = SecurityValueSite.enclosingNames(of: Syntax(node))
            let returned = SecurityContext.Site(
                destination: .returned(fromFunction: node.name.text),
                enclosingFunctions: names.functions, enclosingTypes: names.types)
            let returnType = node.signature.returnClause.map { Self.typeWord($0.type) } ?? ""
            if SecurityContext.isSecurityContext(returned)
                || SecurityContext.isSecurityContext(SecurityContext.Site(destination: .binding(name: returnType))) {
                generatorSeams += 1
            }
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.takesGenerator(node.signature, generics: node.genericParameterClause, where: node.genericWhereClause),
           let type = SecurityValueSite.enclosingNames(of: Syntax(node)).types.last,
           SecurityContext.isSecurityContext(SecurityContext.Site(destination: .binding(name: type))) {
            generatorSeams += 1
        }
        return .visitChildren
    }

    /// The identifier a return type names: `Session`, `APIKey`; empty for `String?` → `String`.
    private static func typeWord(_ type: TypeSyntax) -> String {
        String(type.trimmedDescription.filter { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    /// Whether a signature accepts a `RandomNumberGenerator` — the test `stochastic-no-seed` uses.
    static func takesGenerator(
        _ signature: FunctionSignatureSyntax,
        generics: GenericParameterClauseSyntax?,
        where clause: GenericWhereClauseSyntax?
    ) -> Bool {
        let texts = signature.parameterClause.parameters.map(\.type.trimmedDescription)
            + (generics?.parameters.compactMap { $0.inheritedType?.trimmedDescription } ?? [])
            + (clause?.requirements.map(\.trimmedDescription) ?? [])
        return texts.contains { $0.contains("RandomNumberGenerator") }
    }
}
