import Foundation
#if canImport(os)
import os
#endif

/// Parses a `Package.swift` manifest into a first-party module dependency graph.
///
/// This is the *declared* graph — the fallback used when the IndexStore semantic
/// pass is unavailable. Edge `A → B` means target `A` declares a dependency on
/// first-party target `B`. External `.product(...)` dependencies are dropped: any
/// quoted dependency that is not itself a declared target name is filtered out.
enum PackageGraphLoader {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "PackageGraphLoader")

    /// A parsed target and its raw quoted dependency names.
    struct Target: Sendable, Equatable {
        /// The target's name.
        let name: String
        /// Every quoted string inside the target's `dependencies:` list (both
        /// first-party target names and external product names — filtering to
        /// first-party happens in ``declaredGraph(packageSource:includingTestTargets:)``).
        let dependencies: [String]
        /// Whether this is a `.testTarget` (excluded from the human reading order).
        let isTest: Bool

        /// Creates a parsed target.
        init(name: String, dependencies: [String], isTest: Bool = false) {
            self.name = name
            self.dependencies = dependencies
            self.isTest = isTest
        }
    }

    /// Parses all `.target` / `.executableTarget` / `.testTarget` declarations.
    static func parseTargets(packageSource: String) -> [Target] {
        let targetPattern = #"\.(target|executableTarget|testTarget)\s*\(\s*name:\s*"([^"]+)"([^)]*)\)"#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: targetPattern, options: .dotMatchesLineSeparators)
        } catch {
            Self.logger.warning("Failed to compile target regex: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let source = packageSource as NSString
        let matches = regex.matches(in: packageSource, range: NSRange(location: 0, length: source.length))

        var targets: [Target] = []
        for match in matches where match.numberOfRanges >= 4 {
            let kind = source.substring(with: match.range(at: 1))
            let name = source.substring(with: match.range(at: 2))
            let tail = source.substring(with: match.range(at: 3))
            targets.append(Target(name: name, dependencies: parseDependencies(from: tail), isTest: kind == "testTarget"))
        }
        return targets
    }

    /// Builds the first-party declared dependency graph.
    ///
    /// - Parameter includingTestTargets: When `false` (the default for the human
    ///   reading order), `.testTarget`s are dropped — they add noise without
    ///   telling a newcomer anything about how the system fits together.
    static func declaredGraph(packageSource: String, includingTestTargets: Bool = true) -> ModuleGraph {
        var targets = parseTargets(packageSource: packageSource)
        if !includingTestTargets {
            targets = targets.filter { !$0.isTest }
        }
        let firstParty = Set(targets.map(\.name))

        // Every first-party target is a node — a dependency-less target is
        // still a module a reader must meet (single-module packages are the
        // common case for `orient`).
        var edges: [String: Set<String>] = [:]
        for target in targets {
            edges[target.name] = Set(target.dependencies.filter { firstParty.contains($0) })
        }
        return ModuleGraph(edges: edges)
    }

    /// The identities of the external packages this manifest is **built from** —
    /// parsed from `.package(url:)` / `.package(path:)` entries. Identity is the
    /// last path component, minus any `.git` suffix (e.g.
    /// `https://github.com/jpurnell/BusinessMath` → `BusinessMath`). Returns every
    /// external package, sorted and de-duplicated; filtering to first-party
    /// portfolio packages happens downstream (the dashboard intersects these with
    /// the set of known corpus projects).
    static func externalPackageDependencies(packageSource: String) -> [String] {
        let pattern = #"\.package\(\s*(?:url|path|id):\s*"([^"]+)""#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            Self.logger.warning("Failed to compile package-dependency regex: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let ns = packageSource as NSString
        let matches = regex.matches(in: packageSource, range: NSRange(location: 0, length: ns.length))
        var identities: Set<String> = []
        for match in matches where match.numberOfRanges >= 2 {
            identities.insert(packageIdentity(from: ns.substring(with: match.range(at: 1))))
        }
        return identities.sorted()
    }

    /// A non-actionable package description embedded in the manifest as a comment
    /// `// legibility:description: <text>` — a structured, build-inert home for the
    /// package's "what it does", co-located with its dependencies. `nil` when absent.
    static func packageDescription(packageSource: String) -> String? {
        for rawLine in packageSource.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let range = line.range(of: #"//\s*legibility:description:\s*"#, options: .regularExpression) else {
                continue
            }
            let text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// The package identity from a URL or path: last path component, minus `.git`.
    static func packageIdentity(from location: String) -> String {
        let trimmed = location.hasSuffix("/") ? String(location.dropLast()) : location
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    /// Extracts the quoted strings inside a target tail's `dependencies: [...]`.
    private static func parseDependencies(from tail: String) -> [String] {
        guard let depsRange = tail.range(of: #"dependencies:\s*\["#, options: .regularExpression) else {
            return []
        }
        let afterDeps = String(tail[depsRange.upperBound...])
        let depRegex: NSRegularExpression
        do {
            depRegex = try NSRegularExpression(pattern: #""([^"]+)""#)
        } catch {
            Self.logger.warning("Failed to compile dependency regex: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let ns = afterDeps as NSString
        let matches = depRegex.matches(in: afterDeps, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            match.numberOfRanges >= 2 ? ns.substring(with: match.range(at: 1)) : nil
        }
    }
}
