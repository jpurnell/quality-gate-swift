import Foundation
import SwiftParser
import SwiftSyntax

/// Which release of a library a package builds against, and how the inventory knows.
///
/// A library's facts change between releases. SwiftMCPServer before 5.0.0 bound `0.0.0.0` with
/// no way to narrow it; from 5.0.0 it binds `127.0.0.1` unless told otherwise. A row read with
/// the wrong release's facts is wrong in a direction nobody can see from the row, so the release
/// is recorded beside the rows, with the evidence for it, and printed in the summary.
public struct LibraryRelease: Sendable, Codable, Hashable {

    /// What the release was read from, strongest first.
    public enum Evidence: String, Sendable, Codable, Hashable {
        /// A requirement in `Package.swift` that admits one major version: `from:`, `exact:`,
        /// `.upToNextMajor(from:)`, `.upToNextMinor(from:)`, or a range inside one major.
        case manifest
        /// The version `Package.resolved` pins, where the manifest leaves the major open (a
        /// branch, a revision, a range across majors) or does not name the library at all.
        case resolved
        /// Calls only one generation of the library accepts, where neither file decides.
        case apiShape = "api-shape"
        /// Nothing decided it; the current release's facts were used.
        case assumed
    }

    /// The library, as its package is named: `SwiftMCPServer`.
    public var library: String
    /// The major version the rows were read with.
    public var major: Int
    /// What it was read from.
    public var evidence: Evidence
    /// The evidence, as printed: `from: "4.4.1" in Package.swift`.
    public var detail: String

    /// Creates a release.
    public init(library: String, major: Int, evidence: Evidence, detail: String) {
        self.library = library
        self.major = major
        self.evidence = evidence
        self.detail = detail
    }

    /// The first major version of SwiftMCPServer that binds loopback unless asked for more.
    public static let swiftMCPServerLoopbackMajor = 5

    /// Whether a listener with no address in source binds `127.0.0.1` in this release.
    public var bindsLoopbackByDefault: Bool { major >= Self.swiftMCPServerLoopbackMajor }

    /// One clause for the inventory's summary: the release, the evidence, and what follows.
    public var summary: String {
        let consequence = bindsLoopbackByDefault
            ? "binds 127.0.0.1 unless source says otherwise; --host at launch is not visible"
            : "binds 0.0.0.0 and takes no host"
        return "\(library) read as \(major).x (\(detail)): \(consequence)"
    }
}

/// What a package declares about its dependencies: the text of `Package.swift` and of
/// `Package.resolved`, read and never evaluated.
///
/// Text rather than paths so the inventory stays a function of its inputs — a caller on disk
/// reads the two files, a test hands in a string — and nothing here resolves, fetches or builds.
public struct PackageDependencies: Sendable, Hashable {
    /// The text of `Package.swift`, when there is one.
    public var manifest: String?
    /// The text of `Package.resolved`, when there is one.
    public var resolved: String?

    /// Creates a record from the two files' text.
    public init(manifest: String? = nil, resolved: String? = nil) {
        self.manifest = manifest
        self.resolved = resolved
    }

    /// Neither file: a single source audited alone, or a directory that is not a package.
    public static let unknown = PackageDependencies()

    /// The release of `library` the package declares, or `nil` when neither file decides.
    ///
    /// The manifest is read first, because a requirement that admits one major version decides
    /// the question whatever the pin says: SwiftPM will not build against a pin the manifest
    /// excludes, it re-resolves. The pin is read where the manifest leaves the major open — a
    /// branch, a revision, a range across majors — or does not name the library, which is how a
    /// transitive dependency looks. A `path:` dependency has no requirement and no pin, and is
    /// `nil`.
    ///
    /// - Parameter library: The package's name, compared without case: `SwiftMCPServer`.
    /// - Returns: The declared release, or `nil`.
    public func release(of library: String) -> LibraryRelease? {
        let requirement = manifest.flatMap { ManifestRequirementFinder.requirement(of: library, in: $0) }
        let pin = resolved.flatMap { ResolvedPins.version(of: library, in: $0) }
        let pinMajor = pin.flatMap(Self.major(of:))
        if let requirement, let major = requirement.major {
            var detail = "\(requirement.text) in Package.swift"
            if let pin, let pinMajor {
                detail += pinMajor == major ? ", \(pin) in Package.resolved" : "; Package.resolved still pins \(pin)"
            }
            return LibraryRelease(library: library, major: major, evidence: .manifest, detail: detail)
        }
        guard let pin, let pinMajor else { return nil }
        return LibraryRelease(library: library, major: pinMajor, evidence: .resolved,
                              detail: "\(pin) in Package.resolved")
    }

    /// The leading integer of a semantic version: 4 for `4.5.0`, 3 for `3.0.0-alpha.7`.
    static func major(of version: String) -> Int? {
        Int(version.prefix { $0.isNumber })
    }
}

/// A requirement on one dependency, as `Package.swift` writes it.
struct ManifestRequirement: Equatable {
    /// The requirement's source text: `from: "4.4.1"`.
    var text: String
    /// The one major version it admits, or `nil` when it admits several or names none.
    var major: Int?
}

/// Finds the `.package(…)` call for one library in a manifest's syntax tree.
final class ManifestRequirementFinder: SyntaxVisitor {
    private let library: String
    private(set) var requirement: ManifestRequirement?

    /// Requirement spellings whose single version argument fixes the major.
    private static let singleVersionLabels: Set<String> = ["from", "exact"]
    /// The same, written as a member call: `.upToNextMajor(from: "4.0.0")`.
    private static let singleVersionCalls: Set<String> = ["upToNextMajor", "upToNextMinor", "exact"]

    private init(library: String) {
        self.library = library.lowercased()
        super.init(viewMode: .sourceAccurate)
    }

    /// The requirement `source` places on `library`, or `nil` when it does not name it.
    static func requirement(of library: String, in source: String) -> ManifestRequirement? {
        let finder = ManifestRequirementFinder(library: library)
        finder.walk(Parser.parse(source: source))
        return finder.requirement
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard requirement == nil, SyntaxReading.calleeName(node) == "package" else { return .visitChildren }
        let location = SyntaxReading.stringValue(SyntaxReading.argument(node, labelled: "url"))
            ?? SyntaxReading.stringValue(SyntaxReading.argument(node, labelled: "path"))
        guard let location, Self.identity(of: location) == library else { return .visitChildren }
        let rest = node.arguments.filter { $0.label?.text != "url" && $0.label?.text != "path" && $0.label?.text != "name" }
        guard let first = rest.first else {
            requirement = ManifestRequirement(text: "path: \"\(location)\"", major: nil)
            return .skipChildren
        }
        let text = (first.label.map { "\($0.text): " } ?? "") + first.expression.trimmedDescription
        requirement = ManifestRequirement(text: text, major: Self.major(label: first.label?.text, value: first.expression))
        return .skipChildren
    }

    /// SwiftPM's identity for a location: the last path component, without `.git`, lowercased.
    static func identity(of location: String) -> String {
        let last = (location.split(separator: "/").last.map(String.init) ?? location).lowercased()
        let suffix = ".git"
        return last.hasSuffix(suffix) ? String(last.dropLast(suffix.count)) : last
    }

    /// The single major version a requirement admits, if it admits only one.
    private static func major(label: String?, value: ExprSyntax) -> Int? {
        if let label {
            guard singleVersionLabels.contains(label) else { return nil }
            return SyntaxReading.stringValue(value).flatMap(PackageDependencies.major(of:))
        }
        if let call = value.as(FunctionCallExprSyntax.self), let name = SyntaxReading.calleeName(call),
           singleVersionCalls.contains(name) {
            return SyntaxReading.stringValue(call.arguments.first?.expression).flatMap(PackageDependencies.major(of:))
        }
        return rangeMajor(value)
    }

    /// `"4.2.0"..<"5.0.0"` and `"4.2.0"..."4.9.0"` admit one major; `"4.2.0"..<"6.0.0"` does not.
    private static func rangeMajor(_ value: ExprSyntax) -> Int? {
        guard let sequence = value.as(SequenceExprSyntax.self) else { return nil }
        let elements = Array(sequence.elements)
        guard elements.count == 3, let op = elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text,
              let lowerText = SyntaxReading.stringValue(elements[0]),
              let upperText = SyntaxReading.stringValue(elements[2]),
              let lower = PackageDependencies.major(of: lowerText),
              let upper = PackageDependencies.major(of: upperText) else { return nil }
        if lower == upper { return lower }
        // An exclusive upper bound of the next major's first version: `..<"5.0.0"`.
        let upperIsNextMajorStart = upperText == "\(lower + 1).0.0"
        return op == "..<" && upperIsNextMajorStart ? lower : nil
    }
}

/// The pins of a `Package.resolved`, in either format SwiftPM has written.
enum ResolvedPins {

    /// Format 2 and 3: `pins` at the top, each with an `identity`.
    private struct Current: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { let version: String? }
            let identity: String
            let state: State
        }
        let pins: [Pin]
    }

    /// Format 1: `object.pins`, each with a `package` name.
    private struct Legacy: Decodable {
        struct Object: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { let version: String? }
                let package: String
                let state: State
            }
            let pins: [Pin]
        }
        let object: Object
    }

    /// The version `library` is pinned at, or `nil` — not pinned, pinned to a branch or a
    /// revision with no version, or a file that is not a `Package.resolved`.
    static func version(of library: String, in json: String) -> String? {
        let data = Data(json.utf8)
        let name = library.lowercased()
        let decoder = JSONDecoder()
        if let current = try? decoder.decode(Current.self, from: data) { // silent: a format 1 file fails here by design and is decoded below
            return current.pins.first { $0.identity.lowercased() == name }?.state.version
        }
        if let legacy = try? decoder.decode(Legacy.self, from: data) { // silent: a file in neither format declares no pin, which is the nil this returns
            return legacy.object.pins.first { $0.package.lowercased() == name }?.state.version
        }
        return nil
    }
}
