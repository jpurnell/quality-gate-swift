import Foundation

/// The kind of SwiftPM target a file belongs to, which is a proxy for **who calls it**.
///
/// The proxy is coarse and deliberately so: a CLI whose logic lives in its executable target
/// gets the strict reading, which is correct by the letter and arguably wrong in spirit — but
/// the workaround is to move that logic into a library target, which authors should be doing
/// anyway. The incentive points the right way.
public enum TargetType: String, Sendable, Codable, CaseIterable, Equatable {

    /// The caller is an end user. A logic failure becomes a crash they experience and cannot
    /// act on.
    case executable

    /// The caller is another programmer, at their desk, with a stack trace.
    case library

    /// The caller is the author, and a trap *is* how a test fails.
    case test

    /// The caller is SwiftPM. A trap surfaces as a build failure with a stack trace to the
    /// plugin's author, never to an end user — so it follows ``library``.
    case plugin
}

/// Resolves a source file to the type of the SwiftPM target that owns it.
///
/// Built from `swift package describe --type json`, which reports each target's `path`. A file
/// belongs to the target with the longest matching path prefix, so a nested target directory
/// resolves to the nested target rather than its parent.
public struct TargetTypeMap: Sendable {

    /// One target, as SwiftPM describes it.
    public struct Target: Sendable, Equatable {
        /// Target name.
        public let name: String
        /// SwiftPM's type string: `library`, `executable`, `test`, `plugin`, …
        public let type: String
        /// Path relative to the package root, e.g. `Sources/MyLib`.
        public let path: String

        /// Creates a target descriptor.
        public init(name: String, type: String, path: String) {
            self.name = name
            self.type = type
            self.path = path
        }
    }

    private let targets: [Target]

    /// Creates a map over the package's targets.
    public init(targets: [Target]) {
        // Longest path first, so a nested target wins over its parent.
        self.targets = targets.sorted { $0.path.count > $1.path.count }
    }

    /// How many targets this map holds. Exposed so a caller can tell "no targets" from
    /// "targets that matched nothing", which are different failures.
    public var targetCount: Int { targets.count }

    /// Builds the map from SwiftPM's directory convention alone, reading no manifest.
    ///
    /// The fallback when the manifest cannot be parsed, and the whole answer for a package that
    /// has none. SwiftPM's layout rules make this reliable for a conventional package: a
    /// directory under `Sources/` is a target, under `Tests/` a test target, under `Plugins/` a
    /// plugin. A target with an explicit `path:` in its manifest is the case this cannot see,
    /// which is why it is the fallback rather than the primary.
    ///
    /// Deliberately no subprocess: it enumerates directories. Asking SwiftPM instead is what
    /// downloaded 2.7 GB across nine surveyed packages to answer a question about four folder
    /// names.
    ///
    /// - Parameter packageRoot: Directory containing the package.
    /// - Returns: A map over whatever the convention reveals; empty when nothing matches.
    public static func fromLayout(packageRoot: String) -> TargetTypeMap {
        let manager = FileManager.default
        var found: [Target] = []
        // The three source spellings SwiftPM permits, plus the two other trees a package owns.
        let containers: [(String, String)] = [
            ("Sources", "library"), ("Source", "library"), ("src", "library"),
            ("Tests", "test"), ("Plugins", "plugin"),
        ]
        for (container, type) in containers {
            let base = (packageRoot as NSString).appendingPathComponent(container)
            // silent: most packages have only some of these directories; absence is ordinary.
            let entries = (try? manager.contentsOfDirectory(atPath: base)) ?? []
            for entry in entries where !entry.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                let full = (base as NSString).appendingPathComponent(entry)
                guard manager.fileExists(atPath: full, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                found.append(Target(name: entry, type: type,
                                    path: "\(container)/\(entry)"))
            }
        }
        return TargetTypeMap(targets: found)
    }


    /// The target type owning `file`.
    ///
    /// **Unresolvable files are ``TargetType/executable``**, which is the strict reading. A
    /// malformed `describe`, a path outside every target, or a target type SwiftPM adds later
    /// must not silently relax the rule — failing strict makes a resolution bug loud rather
    /// than permissive.
    ///
    /// - Parameter file: An absolute or package-relative path.
    /// - Returns: The owning target's type, or `.executable` when it cannot be determined.
    public func targetType(forFile file: String) -> TargetType {
        for target in targets where file.contains(target.path) {
            return TargetType(rawValue: target.type) ?? .executable
        }
        return .executable
    }
}

/// What to do about a trap — `fatalError`, `precondition`, `assertionFailure`.
public enum TrapPolicy: String, Sendable, Codable, CaseIterable, Equatable {

    /// Report in executables; count the rest into one note. The default.
    ///
    /// Chosen as the default because it is the only setting that is honest about code you do
    /// not own. A survey of thirty repositories cannot demand annotations, and reporting 73
    /// findings against `Collection` conformances is the wall that gets a checker excluded.
    case aggregate

    /// Report in executables; ask for a `// Justification:` comment elsewhere.
    ///
    /// The mechanism this project already uses for `@unchecked Sendable`. Right for a codebase
    /// that has decided to hold that line for itself, and unreasonable to impose on anyone
    /// else — which is why it is a choice rather than the default.
    case justified

    /// Report everywhere. The behaviour before this policy existed, kept reachable.
    case forbidden

    /// The default policy.
    public static let `default` = TrapPolicy.aggregate

    /// What a trap warrants.
    /// What to do about one trap.
    ///
    /// A typealias since the shape moved to ``GraduatedPolicy``: the three outcomes were never
    /// specific to traps, and `TrapPolicy.Verdict` stays spelled the same at every call site.
    public typealias Verdict = PolicyVerdict

    /// Message fragments that mark a trap as unfinished work rather than a contract.
    ///
    /// Matched case-insensitively. This is the narrow rule that survives the relaxation, and it
    /// is more defensible than the one it replaces: a trap saying "unimplemented" is not a
    /// protocol's documented precondition, it is work that was not done — shipped somewhere
    /// another program will reach it.
    static let unfinishedWorkMarkers = [
        "unimplemented", "todo", "not implemented", "fixme", "unreachable",
    ]

    /// Whether a trap in this target, with this message, is a finding.
    ///
    /// - Parameters:
    ///   - targetType: The owning target's type.
    ///   - message: The trap's message literal, when it has one.
    /// - Returns: The verdict.
    public func verdict(targetType: TargetType, message: String?) -> Verdict {
        verdict(in: targetType, evidence: message)
    }

    /// Whether a trap message describes work that was not done.
    static func namesUnfinishedWork(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return unfinishedWorkMarkers.contains { lowered.contains($0) }
    }
}

// MARK: - GraduatedPolicy

/// Traps, as a graduated policy.
///
/// The ladder — escalation, strict context, level — now lives in ``GraduatedPolicy`` rather than
/// here. This conformance supplies only what is specific to traps, which is the test of whether
/// that shape is right: a level, one context predicate, one escalation, and a noun.
extension TrapPolicy: GraduatedPolicy {

    /// The strength this policy is being held at.
    public var level: PolicyLevel {
        switch self {
        case .forbidden: return .forbidden
        case .justified: return .justified
        case .aggregate: return .aggregate
        }
    }

    /// An executable's caller is an end user, so the relaxation never applies there.
    ///
    /// - Parameter context: The owning target's type.
    /// - Returns: `true` for an executable target.
    public func alwaysReports(in context: TargetType) -> Bool {
        context == .executable
    }

    /// A trap naming unfinished work is not a documented precondition.
    ///
    /// - Parameter evidence: The trap's message literal, when it has one.
    /// - Returns: `true` when the message names work that was not done.
    public func escalates(_ evidence: String?) -> Bool {
        guard let evidence else { return false }
        return Self.namesUnfinishedWork(evidence)
    }

    /// The noun the aggregate note counts.
    public var aggregateNoun: String { "trap" }
}
