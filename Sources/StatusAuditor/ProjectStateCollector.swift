import Foundation

/// Actual state of a module from the file system.
public struct ActualModuleState: Sendable, Equatable {
    /// Module name (directory name under Sources/).
    public let name: String

    /// Number of .swift source files in the module directory.
    public let sourceFileCount: Int

    /// Total lines of Swift source code in the module.
    public let sourceLineCount: Int

    /// Number of .swift test files in the corresponding test directory.
    public let testFileCount: Int

    /// Approximate test count based on @Test and func test occurrences.
    public let estimatedTestCount: Int

    /// Whether this module appears as a target in Package.swift.
    public let existsInPackageSwift: Bool
}

/// Collects actual module state from the file system and Package.swift.
public enum ProjectStateCollector {

    /// Collect state for all modules found in Sources/ and Package.swift.
    ///
    /// - Parameters:
    ///   - sourcesPath: Path to the Sources/ directory.
    ///   - testsPath: Path to the Tests/ directory.
    ///   - packagePath: Path to Package.swift.
    /// - Returns: Dictionary mapping module name to its actual state.
    public static func collectModuleStates(
        sourcesPath: String,
        testsPath: String,
        packagePath: String
    ) -> [String: ActualModuleState] {
        let fileManager = FileManager.default
        let packageTargets = parsePackageTargets(at: packagePath)

        var states: [String: ActualModuleState] = [:]

        // Collect all module names from Sources/ directories AND Package.swift targets
        var moduleNames = Set(packageTargets)

        if let sourceDirs = try? fileManager.contentsOfDirectory(atPath: sourcesPath) {
            for dir in sourceDirs {
                let dirPath = (sourcesPath as NSString).appendingPathComponent(dir)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue {
                    moduleNames.insert(dir)
                }
            }
        }

        for moduleName in moduleNames {
            let modulePath = (sourcesPath as NSString).appendingPathComponent(moduleName)
            let testDirName = "\(moduleName)Tests"
            let testPath = (testsPath as NSString).appendingPathComponent(testDirName)

            let (sourceFileCount, sourceLineCount) = countSwiftFiles(at: modulePath)
            let (testFileCount, _) = countSwiftFiles(at: testPath)
            let estimatedTests = countTestOccurrences(at: testPath)

            states[moduleName] = ActualModuleState(
                name: moduleName,
                sourceFileCount: sourceFileCount,
                sourceLineCount: sourceLineCount,
                testFileCount: testFileCount,
                estimatedTestCount: estimatedTests,
                existsInPackageSwift: packageTargets.contains(moduleName)
            )
        }

        return states
    }

    // MARK: - Private Helpers

    /// Parse target names from Package.swift.
    static func parsePackageTargets(at path: String) -> Set<String> {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }

        var targets: Set<String> = []
        let patterns = [
            #"\.target\s*\(\s*name:\s*"([^"]+)""#,
            #"\.executableTarget\s*\(\s*name:\s*"([^"]+)""#,
            #"\.testTarget\s*\(\s*name:\s*"([^"]+)""#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.matches(in: content, range: range)

            for match in matches {
                if let nameRange = Range(match.range(at: 1), in: content) {
                    targets.insert(String(content[nameRange]))
                }
            }
        }

        return targets
    }

    /// Count Swift files and total lines in a directory.
    static func countSwiftFiles(at path: String) -> (fileCount: Int, lineCount: Int) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return (0, 0)
        }

        var fileCount = 0
        var lineCount = 0

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            fileCount += 1

            if let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                lineCount += content.components(separatedBy: .newlines).count
            }
        }

        return (fileCount, lineCount)
    }

    /// Estimate test count by counting @Test and func test occurrences.
    static func countTestOccurrences(at path: String) -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return 0
        }

        var count = 0

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                continue
            }

            // Count @Test attributes (Swift Testing)
            let testAttrPattern = #"@Test\b"#
            if let regex = try? NSRegularExpression(pattern: testAttrPattern) {
                let range = NSRange(content.startIndex..., in: content)
                count += regex.numberOfMatches(in: content, range: range)
            }

            // Count func test* methods (XCTest)
            let funcTestPattern = #"func\s+test[A-Z]\w*\s*\("#
            if let regex = try? NSRegularExpression(pattern: funcTestPattern) {
                let range = NSRange(content.startIndex..., in: content)
                count += regex.numberOfMatches(in: content, range: range)
            }
        }

        return count
    }
}
