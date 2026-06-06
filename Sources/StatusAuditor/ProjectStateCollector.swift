import Foundation
import os

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
    private static let logger = Logger(subsystem: "com.quality-gate", category: "ProjectStateCollector")

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

        // Collect all module names from Sources/, Plugins/, and Package.swift targets
        var moduleNames = Set(packageTargets)

        // Check both Sources/ and Plugins/ directories (SPM plugins live under Plugins/)
        let searchPaths = [sourcesPath, (sourcesPath as NSString)
            .deletingLastPathComponent
            .appending("/Plugins")]

        for searchPath in searchPaths {
            let dirs: [String]
            do {
                dirs = try fileManager.contentsOfDirectory(atPath: searchPath) // SAFETY: CLI tool enumerates local project modules
            } catch {
                logger.warning("Could not list directory \(searchPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            for dir in dirs {
                let dirPath = (searchPath as NSString).appendingPathComponent(dir)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue { // SAFETY: CLI tool checks local directory type
                    moduleNames.insert(dir)
                }
            }
        }

        let pluginsPath = (sourcesPath as NSString)
            .deletingLastPathComponent
            .appending("/Plugins")

        for moduleName in moduleNames {
            // Check Sources/ first, fall back to Plugins/
            var modulePath = (sourcesPath as NSString).appendingPathComponent(moduleName)
            if !fileManager.fileExists(atPath: modulePath) { // SAFETY: CLI tool checks local module path
                let pluginPath = (pluginsPath as NSString).appendingPathComponent(moduleName)
                if fileManager.fileExists(atPath: pluginPath) { // SAFETY: CLI tool checks local plugin path
                    modulePath = pluginPath
                }
            }
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
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            logger.warning("Could not read Package.swift at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        var targets: Set<String> = []
        let patterns = [
            #"\.target\s*\(\s*name:\s*"([^"]+)""#,
            #"\.executableTarget\s*\(\s*name:\s*"([^"]+)""#,
            #"\.testTarget\s*\(\s*name:\s*"([^"]+)""#,
        ]

        for pattern in patterns {
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern)
            } catch {
                logger.warning("Failed to compile target regex pattern: \(error.localizedDescription, privacy: .public)")
                continue
            }
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

            do {
                let content = try String(contentsOfFile: fullPath, encoding: .utf8)
                lineCount += content.components(separatedBy: .newlines).count
            } catch {
                logger.warning("Skipping unreadable source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            let content: String
            do {
                content = try String(contentsOfFile: fullPath, encoding: .utf8)
            } catch {
                logger.warning("Skipping unreadable test file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }

            // Count @Test attributes (Swift Testing)
            let testAttrPattern = #"@Test\b"#
            do {
                let regex = try NSRegularExpression(pattern: testAttrPattern)
                let range = NSRange(content.startIndex..., in: content)
                count += regex.numberOfMatches(in: content, range: range)
            } catch {
                logger.warning("Failed to compile @Test regex: \(error.localizedDescription, privacy: .public)")
            }

            // Count func test* methods (XCTest)
            let funcTestPattern = #"func\s+test[A-Z]\w*\s*\("#
            do {
                let regex = try NSRegularExpression(pattern: funcTestPattern)
                let range = NSRange(content.startIndex..., in: content)
                count += regex.numberOfMatches(in: content, range: range)
            } catch {
                logger.warning("Failed to compile func-test regex: \(error.localizedDescription, privacy: .public)")
            }
        }

        return count
    }
}
