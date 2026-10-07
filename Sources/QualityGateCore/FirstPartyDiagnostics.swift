// FirstPartyDiagnostics.swift
// QualityGateCore
//
// Scopes non-error diagnostics to first-party source so warnings originating
// in dependency checkouts or build artifacts are not attributed to the
// project under audit — under SwiftPM and under Xcode alike.

import QualityGateTypes

/// Where a diagnostic that is not about the package under audit comes from.
///
/// ## The one definition of "first-party"
///
/// Every checker that reads a build's diagnostics — `build`, `xcode-build`, `doc-lint` — asks
/// this type, so they cannot disagree about whose a warning is. A path is **not** first-party
/// when it lies in one of the places a build system keeps things it fetched or produced:
///
/// | Path contains | Build system | Origin |
/// |---|---|---|
/// | `/.build/checkouts/<package>/` | SwiftPM | ``package(_:)`` |
/// | `/.build/artifacts/<package>/` | SwiftPM | ``package(_:)`` |
/// | `/.build/` otherwise | SwiftPM | ``buildDirectory`` |
/// | `/SourcePackages/checkouts/<package>/` | Xcode (DerivedData) | ``package(_:)`` |
/// | `/SourcePackages/artifacts/<package>/` | Xcode (DerivedData) | ``package(_:)`` |
///
/// Everything else is first-party, which is the direction to be wrong in: an unrecognised
/// path is counted, never dropped.
///
/// ## Why markers, and not "is the path inside the package root?"
///
/// Containment in the root is the question one would like to ask, and it gives the wrong
/// answer three ways:
///
/// - SwiftPM puts dependency checkouts **inside** the root, at `.build/checkouts/`.
/// - Xcode puts the package's own derived sources **outside** it — `resource_bundle_accessor.swift`
///   and `GeneratedAssetSymbols.swift` under `DerivedData/…/Build/Intermediates.noindex/`,
///   build-tool plugin output under `DerivedData/…/SourcePackages/plugins/`, macro expansion
///   buffers in a temporary directory. A warning there is about this package's code.
/// - A local path dependency lives outside the root and has always been counted: it is
///   compiled from an editable directory its author can fix, and `build` reports its warnings
///   on purpose. So is a package under `swift package edit`, in `Packages/`.
///
/// The root is still used, for the one thing it is right about: a path inside it is judged by
/// what follows the root. A package that is itself checked out at `…/.build/checkouts/App` or
/// `…/SourcePackages/checkouts/App` owns its sources, wherever its parent directory is.
///
/// ## What is deliberately not recognised
///
/// A dependency's *derived* sources under Xcode
/// (`DerivedData/…/Intermediates.noindex/<dependency>.build/…`) have the same shape as the
/// package's own, and telling them apart needs the package graph rather than the path. They
/// stay counted.
public enum DependencyOrigin: Sendable, Hashable {
    /// Inside a fetched package: a source checkout or a binary artifact.
    case package(String)
    /// Inside SwiftPM's build directory, but not in a package checkout: build products,
    /// intermediates, plugin output.
    case buildDirectory

    /// SwiftPM's build directory, as a path component.
    private static let buildDirectoryMarker = "/.build/"

    /// Directories that hold one subdirectory per fetched package, under each build system.
    private static let packageDirectoryMarkers = [
        "/.build/checkouts/",
        "/.build/artifacts/",
        "/SourcePackages/checkouts/",
        "/SourcePackages/artifacts/",
    ]

    /// The dependency a path belongs to, or `nil` when the path is first-party.
    ///
    /// - Parameters:
    ///   - path: A file path from a diagnostic, absolute as build tools report it.
    ///   - projectRoot: The root of the package under audit, or `nil` when it is not known —
    ///     the path is then judged as written.
    /// - Returns: The origin, or `nil` for a path that counts against the package.
    public static func of(path: String, projectRoot: String?) -> DependencyOrigin? {
        origin(in: relativized(path, projectRoot: projectRoot))
    }

    /// The dependency named by a path mentioned in prose, or `nil` when none is.
    ///
    /// Some tools (`docc` among them) report a build artifact with no file path and the
    /// offending location only in the message.
    ///
    /// - Parameters:
    ///   - message: The diagnostic's message.
    ///   - projectRoot: The root of the package under audit, if known.
    /// - Returns: The origin of the first build-system location the message names.
    public static func of(message: String, projectRoot: String?) -> DependencyOrigin? {
        guard let projectRoot, !projectRoot.isEmpty else { return origin(in: message) }
        let root = projectRoot.hasSuffix("/") ? String(projectRoot.dropLast()) : projectRoot
        return origin(in: message.replacingOccurrences(of: root + "/", with: "/"))
    }

    /// The path with the project root removed from its front, when it is inside the root.
    private static func relativized(_ path: String, projectRoot: String?) -> String {
        guard let projectRoot, !projectRoot.isEmpty else { return path }
        let root = projectRoot.hasSuffix("/") ? String(projectRoot.dropLast()) : projectRoot
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count))
    }

    private static func origin(in text: String) -> DependencyOrigin? {
        for marker in packageDirectoryMarkers {
            guard let range = text.range(of: marker) else { continue }
            let name = text[range.upperBound...].prefix { $0 != "/" }
            if !name.isEmpty { return .package(String(name)) }
        }
        return text.contains(buildDirectoryMarker) ? .buildDirectory : nil
    }
}

/// A set of diagnostics divided into what counts against the package and what does not.
///
/// Nothing is dropped silently: when anything was scoped out, ``note`` says how much and from
/// where, and ``reported`` carries it.
public struct FirstPartyScope: Sendable, Equatable {
    /// The rule id of the note that says what was scoped out.
    public static let noteRuleId = "gate.dependency-diagnostics-not-counted"

    /// Diagnostics that count: every error, and every warning or note in first-party source.
    public let counted: [Diagnostic]

    /// Warnings and notes attributed to a dependency or the build directory, in order.
    public let scopedOut: [Diagnostic]

    /// How many diagnostics each origin contributed, largest first, then by name.
    public let origins: [(origin: DependencyOrigin, count: Int)]

    /// One note saying what was not counted, or `nil` when everything was.
    ///
    /// *"20 warnings in dependency mlx-swift were not counted; they are not this package's
    /// source"*.
    public var note: Diagnostic? {
        guard !scopedOut.isEmpty else { return nil }
        let plural = scopedOut.count != 1
        return Diagnostic(
            severity: .note,
            message: "\(Self.tally(scopedOut)) in \(Self.describe(origins)) "
                + (plural ? "were not counted; they are" : "was not counted; it is")
                + " not this package's source",
            ruleId: Self.noteRuleId
        )
    }

    /// What a checker should report: ``counted``, then ``note`` when there is one.
    public var reported: [Diagnostic] {
        counted + (note.map { [$0] } ?? [])
    }

    /// Equal when the same diagnostics were counted and scoped out.
    public static func == (lhs: FirstPartyScope, rhs: FirstPartyScope) -> Bool {
        lhs.counted == rhs.counted && lhs.scopedOut == rhs.scopedOut
    }

    /// "20 warnings", "1 note", "4 warnings and 1 note".
    private static func tally(_ diagnostics: [Diagnostic]) -> String {
        let warnings = diagnostics.count { $0.severity == .warning }
        let notes = diagnostics.count - warnings
        var parts: [String] = []
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        if notes > 0 { parts.append("\(notes) note\(notes == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }

    /// "dependency mlx-swift", "dependencies a (3) and b (1), and the build directory (1),".
    ///
    /// Counts are given per origin only when there is more than one, where the total alone
    /// would not say whose they are.
    private static func describe(_ origins: [(origin: DependencyOrigin, count: Int)]) -> String {
        let several = origins.count > 1
        var packages: [String] = []
        var buildDirectory: String?
        for entry in origins {
            let suffix = several ? " (\(entry.count))" : ""
            switch entry.origin {
            case .package(let name): packages.append(name + suffix)
            case .buildDirectory: buildDirectory = "the build directory" + suffix
            }
        }
        var phrases: [String] = []
        if let only = packages.first, packages.count == 1 {
            phrases.append("dependency \(only)")
        } else if let last = packages.last {
            phrases.append("dependencies \(packages.dropLast().joined(separator: ", ")) and \(last)")
        }
        if let buildDirectory { phrases.append(buildDirectory) }
        return phrases.count > 1 ? phrases.joined(separator: ", and ") + "," : phrases.joined()
    }
}

public extension Array where Element == Diagnostic {
    /// Divides the diagnostics into those that count against the package and those that
    /// belong to a dependency or the build directory.
    ///
    /// A diagnostic is scoped out when it is a `warning` or `note` **and** ``DependencyOrigin``
    /// attributes it elsewhere — by its ``Diagnostic/filePath``, or, for a tool that reports
    /// the artifact only in prose, by its message. Errors are always counted, so a dependency
    /// that fails to build still fails the gate.
    ///
    /// - Parameter projectRoot: The root of the package under audit, if known.
    /// - Returns: The division, with a note describing anything scoped out.
    func firstPartyScope(projectRoot: String? = nil) -> FirstPartyScope {
        var counted: [Diagnostic] = []
        var scopedOut: [Diagnostic] = []
        var counts: [DependencyOrigin: Int] = [:]

        for diagnostic in self {
            guard diagnostic.severity != .error,
                  let origin = Self.origin(of: diagnostic, projectRoot: projectRoot)
            else {
                counted.append(diagnostic)
                continue
            }
            scopedOut.append(diagnostic)
            counts[origin, default: 0] += 1
        }

        let origins = counts
            .map { (origin: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : Self.name(lhs.origin) < Self.name(rhs.origin)
            }
        return FirstPartyScope(counted: counted, scopedOut: scopedOut, origins: origins)
    }

    /// Returns the diagnostics with warnings and notes that originate outside
    /// first-party source removed.
    ///
    /// The counted half of ``firstPartyScope(projectRoot:)``. A checker reporting a result
    /// should prefer ``FirstPartyScope/reported``, which also says what was left out.
    ///
    /// - Parameter projectRoot: The root of the package under audit, if known.
    /// - Returns: The first-party-scoped diagnostics, preserving order.
    func scopedToFirstParty(projectRoot: String? = nil) -> [Diagnostic] {
        firstPartyScope(projectRoot: projectRoot).counted
    }

    /// A located diagnostic is judged by its path alone; only one with no path is judged by
    /// what its message names.
    private static func origin(of diagnostic: Diagnostic, projectRoot: String?) -> DependencyOrigin? {
        if let path = diagnostic.filePath {
            return DependencyOrigin.of(path: path, projectRoot: projectRoot)
        }
        return DependencyOrigin.of(message: diagnostic.message, projectRoot: projectRoot)
    }

    private static func name(_ origin: DependencyOrigin) -> String {
        switch origin {
        case .package(let name): return name
        // Sorts after any package name, so packages are listed first on a tie.
        case .buildDirectory: return "\u{10FFFF}"
        }
    }
}
