import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Which files of a package a target compiles, as far as its manifest says.
///
/// ## Why the audit is scoped at all
///
/// `fallback` reads every `.swift` file under the project root. In a package, some
/// of those are not code the package builds: BusinessMath keeps reference scripts
/// under `project/reference/`, one of them a Markdown code fence saved with a `.swift`
/// extension. Seven conversions in a `#!/usr/bin/env swift` example and one clamp in
/// a file that does not parse as Swift were reported — and baselined — as though they
/// shipped. A finding the owner can only answer by moving a file is not a finding
/// about their code.
///
/// ## Why it errs towards auditing
///
/// A narrower audit is a quieter one, and quiet is the failure this checker exists
/// to prevent. So a file is left out only when the manifest positively shows no
/// target can own it:
///
/// - No `Package.swift`: nothing is known, and every file is audited as before. An
///   Xcode-only project is this case.
/// - A target whose `path:` is computed, or which is rooted at the package directory
///   or outside it: the manifest cannot be read to a list of directories, and every
///   file is audited.
/// - The conventional containers — `Sources`, `Source`, `src`, `srcs`, `Tests`,
///   `Plugins` — are owned whole, whatever targets the manifest names inside them.
/// - A directory holding an `.xcodeproj` or `.xcworkspace` is owned whole: its files
///   may belong to an Xcode target the manifest knows nothing about.
///
/// What is left out is counted, and the count is printed in the coverage note.
struct FallbackTargetScope: Sendable {

    /// SwiftPM's own source containers. A file under one is in a target or is
    /// SwiftPM's error to report, not this checker's to skip.
    private static let conventionalContainers = ["Sources", "Source", "src", "srcs", "Tests", "Plugins"]

    /// How the manifest was read.
    enum Resolution: Sendable, Equatable {
        /// There is no `Package.swift`. Every file is in scope.
        case noManifest
        /// There is one and its target directories could not all be read. Every file
        /// is in scope, and the coverage note says why.
        case unreadable
        /// The directories targets own, package-relative, each as its path components.
        case directories([[String]])
    }

    /// How the manifest was read.
    let resolution: Resolution

    /// Reads the scope of the package at `projectRoot`.
    ///
    /// The manifest is parsed as the Swift source it is. Nothing is resolved and
    /// nothing is run: `swift package describe` compiles the manifest and fetches the
    /// dependency graph to answer a question about directory names.
    ///
    /// - Parameter projectRoot: The directory that may hold a `Package.swift`.
    static func resolve(projectRoot: URL) -> FallbackTargetScope {
        let manifest = projectRoot.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            return FallbackTargetScope(resolution: .noManifest)
        }
        guard let source = SourceFileReader.read(manifest, checker: "fallback") else {
            return FallbackTargetScope(resolution: .unreadable)
        }
        return FallbackTargetScope(manifestSource: source)
    }

    /// Reads the scope a manifest's text declares.
    ///
    /// - Parameter manifestSource: The contents of a `Package.swift`.
    init(manifestSource: String) {
        let collector = TargetPathCollector()
        collector.walk(Parser.parse(source: manifestSource))
        guard !collector.unreadable else {
            self.init(resolution: .unreadable)
            return
        }
        let directories = Self.conventionalContainers + collector.paths
        self.init(resolution: .directories(directories.map(Self.components(of:))))
    }

    private init(resolution: Resolution) {
        self.resolution = resolution
    }

    /// True if a target may compile the file at `relativePath`.
    ///
    /// - Parameter relativePath: The file's path relative to the package root.
    func owns(_ relativePath: String) -> Bool {
        guard case .directories(let directories) = resolution else { return true }
        let file = Self.components(of: relativePath)
        // The manifest itself, and its version-specific siblings.
        if file.count == 1, let name = file.first, name.hasPrefix("Package") { return true }
        // Whole components, so that `Sources2/…` is not taken for `Sources/…`.
        return directories.contains { file.count > $0.count && file.starts(with: $0) }
    }

    /// A package-relative path as its components: `Sources/Core` is `["Sources", "Core"]`.
    private static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}

// MARK: - Manifest

/// Collects the explicit `path:` of every target a manifest declares.
///
/// Every call to a target factory is read, wherever it is written. A manifest need
/// not hand `Package(…)` an array literal: BusinessMath builds `var targets`, appends
/// to it under `#if`, and passes the variable. Reading only the `targets:` argument
/// would have found nothing there and — rightly refusing to guess — audited the very
/// scripts this scope exists to leave out.
///
/// `.target(name:)` inside a `dependencies:` list is a factory call too. It has no
/// `path:`, so it adds nothing, and that is why reading every call is safe.
private final class TargetPathCollector: SyntaxVisitor {

    /// SwiftPM's factories for targets that hold Swift source.
    private static let sourceTargets: Set<String> = ["target", "executableTarget", "testTarget", "plugin", "macro"]

    /// Explicit target directories, package-relative.
    private(set) var paths: [String] = []

    /// Whether a target's directory could not be read from the text.
    private(set) var unreadable = false

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              Self.sourceTargets.contains(member.declName.baseName.text),
              node.arguments.contains(where: { $0.label?.text == "name" }) else {
            return .visitChildren
        }
        read(pathOf: node)
        return .visitChildren
    }

    private func read(pathOf call: FunctionCallExprSyntax) {
        for argument in call.arguments where argument.label?.text == "path" {
            guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
                  let value = literal.representedLiteralValue else {
                // `path: directory`: a target lives somewhere this cannot name.
                unreadable = true
                return
            }
            var path = value
            while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
            while path.hasSuffix("/") { path = String(path.dropLast()) }
            // The package directory itself, or somewhere outside it.
            guard !path.isEmpty, path != ".", !path.hasPrefix("..") else {
                unreadable = true
                return
            }
            paths.append(path)
        }
    }
}

// MARK: - Xcode

/// Answers whether a file sits beside, or beneath, an Xcode project.
///
/// A package that also carries an app keeps the app's sources outside every SwiftPM
/// target, in a directory with an `.xcodeproj`. Those files are compiled — by Xcode —
/// and stay audited. Membership is not read from the project file: a directory that
/// holds a project is taken whole, which can only audit too much.
struct FallbackXcodeClaims {
    private let root: URL
    private var cache: [String: Bool] = [:]

    /// Creates a lookup rooted at `root`.
    init(root: URL) {
        self.root = root
    }

    /// True if the directory of `relativePath`, or any directory above it up to the
    /// root, holds an `.xcodeproj` or an `.xcworkspace`.
    mutating func claims(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }
        // The file's own directory first, then each one above it, ending at the root.
        for depth in stride(from: components.count - 1, through: 0, by: -1) {
            if holdsProject(components.prefix(depth).joined(separator: "/")) { return true }
        }
        return false
    }

    private mutating func holdsProject(_ directory: String) -> Bool {
        if let known = cache[directory] { return known }
        let url = directory.isEmpty ? root : root.appendingPathComponent(directory, isDirectory: true)
        let entries = SourceFileReader.contentsOfDirectory(atPath: url.path, checker: "fallback")
        let found = entries.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        cache[directory] = found
        return found
    }
}
