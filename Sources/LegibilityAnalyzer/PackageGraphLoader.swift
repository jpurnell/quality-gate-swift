import Foundation

/// Parses a `Package.swift` manifest into a first-party module dependency graph.
///
/// This is the *declared* graph — the fallback used when the IndexStore semantic
/// pass is unavailable. Edge `A → B` means target `A` declares a dependency on
/// first-party target `B`. External `.product(...)` dependencies are dropped: any
/// quoted dependency that is not itself a declared target name is filtered out.
public enum PackageGraphLoader {

    /// A parsed target and its raw quoted dependency names.
    public struct Target: Sendable, Equatable {
        /// The target's name.
        public let name: String
        /// Every quoted string inside the target's `dependencies:` list (both
        /// first-party target names and external product names — filtering to
        /// first-party happens in ``declaredGraph(packageSource:includingTestTargets:)``).
        public let dependencies: [String]
        /// Whether this is a `.testTarget` (excluded from the human reading order).
        public let isTest: Bool

        /// Creates a parsed target.
        public init(name: String, dependencies: [String], isTest: Bool = false) {
            self.name = name
            self.dependencies = dependencies
            self.isTest = isTest
        }
    }

    /// Parses all `.target` / `.executableTarget` / `.testTarget` declarations.
    public static func parseTargets(packageSource: String) -> [Target] {
        let targetPattern = #"\.(target|executableTarget|testTarget)\s*\(\s*name:\s*"([^"]+)"([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: targetPattern, options: .dotMatchesLineSeparators) else {
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
    public static func declaredGraph(packageSource: String, includingTestTargets: Bool = true) -> ModuleGraph {
        var targets = parseTargets(packageSource: packageSource)
        if !includingTestTargets {
            targets = targets.filter { !$0.isTest }
        }
        let firstParty = Set(targets.map(\.name))

        var edges: [String: Set<String>] = [:]
        for target in targets {
            let internalDeps = target.dependencies.filter { firstParty.contains($0) }
            if !internalDeps.isEmpty {
                edges[target.name] = Set(internalDeps)
            }
        }
        return ModuleGraph(edges: edges)
    }

    /// Extracts the quoted strings inside a target tail's `dependencies: [...]`.
    private static func parseDependencies(from tail: String) -> [String] {
        guard let depsRange = tail.range(of: #"dependencies:\s*\["#, options: .regularExpression) else {
            return []
        }
        let afterDeps = String(tail[depsRange.upperBound...])
        guard let depRegex = try? NSRegularExpression(pattern: #""([^"]+)""#) else { return [] }

        let ns = afterDeps as NSString
        let matches = depRegex.matches(in: afterDeps, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            match.numberOfRanges >= 2 ? ns.substring(with: match.range(at: 1)) : nil
        }
    }
}
