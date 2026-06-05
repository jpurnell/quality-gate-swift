import Foundation
import IJSAggregator
import IJSSensor
import os

/// Reads quality gate telemetry from a corpus directory.
///
/// Expected layout:
/// ```
/// <corpusPath>/telemetry/<project>/<date>/<timestamp>_metadata.json
/// ```
public struct CorpusReader: Sendable {
    private let corpusPath: String
    private static let logger = Logger(subsystem: "com.quality-gate", category: "CorpusReader")

    /// Creates a reader for the given corpus directory.
    public init(corpusPath: String) {
        self.corpusPath = corpusPath
    }

    /// Discovers all project IDs in the corpus.
    public func discoverProjects() throws -> [String] {
        let telemetryPath = "\(corpusPath)/telemetry" // SAFETY: corpusPath is set by configuration, not user input
        let fm = FileManager.default
        guard fm.fileExists(atPath: telemetryPath) else { return [] } // SAFETY: read-only existence check on configured path
        let contents = try fm.contentsOfDirectory(atPath: telemetryPath) // SAFETY: reads configured corpus directory
        return contents.filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: "\(telemetryPath)/\(name)", isDirectory: &isDir) && isDir.boolValue // SAFETY: reads subdir of configured corpus
        }
    }

    /// Loads all runs for a project, sorted by timestamp.
    public func loadRuns(for project: String) throws -> [TimestampedRun] {
        let projectPath = "\(corpusPath)/telemetry/\(project)" // SAFETY: corpusPath from configuration; project from discoverProjects
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectPath) else { return [] } // SAFETY: read-only existence check

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var runs: [TimestampedRun] = []
        let dateDirs = try fm.contentsOfDirectory(atPath: projectPath) // SAFETY: reads configured corpus subdirectory
        for dateDir in dateDirs {
            let datePath = "\(projectPath)/\(dateDir)" // SAFETY: child of configured corpus path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: datePath, isDirectory: &isDir), isDir.boolValue else { continue } // SAFETY: read-only directory check

            let files = try fm.contentsOfDirectory(atPath: datePath) // SAFETY: reads date subdirectory of corpus
            for file in files where file.hasSuffix("_metadata.json") {
                let filePath = "\(datePath)/\(file)" // SAFETY: child of configured corpus path
                guard let data = fm.contents(atPath: filePath) else { continue } // SAFETY: reads JSON from corpus
                do {
                    let metadata = try decoder.decode(CheckResultMetadata.self, from: data)
                    runs.append(TimestampedRun(metadata: metadata))
                } catch {
                    Self.logger.warning("Skipping malformed JSON at \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
        }

        return runs.sorted { $0.metadata.timestamp < $1.metadata.timestamp }
    }

    /// Loads all projects and their runs.
    public func loadAll() throws -> [String: [TimestampedRun]] {
        let projects = try discoverProjects()
        var result: [String: [TimestampedRun]] = [:]
        for project in projects {
            result[project] = try loadRuns(for: project)
        }
        return result
    }

    // MARK: - Manifest Loading

    /// Loads the corpus manifest from `<corpusPath>/manifest.yml`.
    ///
    /// Returns an empty manifest (treating all projects as active) if the
    /// file does not exist.
    ///
    /// - Returns: The decoded ``CorpusManifest``.
    /// - Throws: ``IJSError/configurationError(reason:)`` if the file exists but cannot be parsed.
    public func loadManifest() throws -> CorpusManifest {
        let manifestURL = URL(fileURLWithPath: "\(corpusPath)/manifest.yml") // SAFETY: corpusPath from configuration
        return try CorpusManifest.load(from: manifestURL)
    }

    // MARK: - Pulse Loading

    /// Loads the most recent InstitutionalPulse from the corpus pulse directory.
    ///
    /// Scans `<corpusPath>/pulse/` for labeled directories (both `YYYY-WNN`
    /// week labels and `YYYY-MM-DD` date labels), sorts chronologically,
    /// then returns the pulse from the latest one.
    /// Returns nil if no pulse directory exists or all files are malformed.
    public func loadLatestPulse() -> InstitutionalPulse? {
        let pulsePath = "\(corpusPath)/pulse" // SAFETY: corpusPath is from configuration
        let fm = FileManager.default
        guard fm.fileExists(atPath: pulsePath) else { return nil } // SAFETY: read-only check on configured path

        // SAFETY: pulsePath derived from validated configuration, read-only listing
        guard let contents = try? fm.contentsOfDirectory(atPath: pulsePath) else { return nil } // silent: empty pulse dir returns nil

        let labelDirs = contents
            .filter { name in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: "\(pulsePath)/\(name)", isDirectory: &isDir) && isDir.boolValue // SAFETY: reads subdir of configured path
            }
            .sorted { lhs, rhs in
                Self.chronologicalDescending(lhs, rhs)
            }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for dirLabel in labelDirs {
            let filePath = "\(pulsePath)/\(dirLabel)/PULSE_\(dirLabel).json" // SAFETY: child of configured pulse path
            guard let data = fm.contents(atPath: filePath) else { continue } // SAFETY: reads pulse JSON
            do {
                return try decoder.decode(InstitutionalPulse.self, from: data)
            } catch {
                Self.logger.warning("Skipping malformed pulse at \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        return nil
    }

    /// Lists all week labels that have a valid pulse JSON file, sorted ascending.
    ///
    /// Delegates to ``listAvailableLabels()`` for backward compatibility.
    public func listAvailableWeeks() -> [String] {
        listAvailableLabels()
    }

    /// Lists all pulse labels (both `YYYY-WNN` and `YYYY-MM-DD` formats) that
    /// have a valid pulse JSON file, sorted chronologically ascending.
    public func listAvailableLabels() -> [String] {
        let pulsePath = "\(corpusPath)/pulse" // SAFETY: corpusPath from configuration
        let fm = FileManager.default
        guard fm.fileExists(atPath: pulsePath) else { return [] } // SAFETY: read-only check on configured path
        guard let contents = try? fm.contentsOfDirectory(atPath: pulsePath) else { return [] } // silent: empty pulse dir returns []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return contents
            .filter { name in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: "\(pulsePath)/\(name)", isDirectory: &isDir), // SAFETY: child of configured pulse path
                      isDir.boolValue else { return false }
                let filePath = "\(pulsePath)/\(name)/PULSE_\(name).json" // SAFETY: child of configured pulse path
                guard let data = fm.contents(atPath: filePath) else { return false } // SAFETY: reads pulse JSON
                return (try? decoder.decode(InstitutionalPulse.self, from: data)) != nil // silent: malformed JSON treated as absent
            }
            .sorted { lhs, rhs in
                Self.chronologicalAscending(lhs, rhs)
            }
    }

    /// Loads a specific pulse by label (date or week format).
    ///
    /// - Parameter label: Pulse label (e.g., "2026-W20" or "2026-06-05").
    /// - Returns: The decoded pulse, or nil if not found or malformed.
    public func loadPulse(label: String) -> InstitutionalPulse? {
        let baseURL = URL(fileURLWithPath: corpusPath).standardized
        let fileURL = baseURL.appendingPathComponent("pulse/\(label)/PULSE_\(label).json").standardized
        guard fileURL.path.hasPrefix(baseURL.path) else { return nil } // SAFETY: reject path traversal
        let fm = FileManager.default
        guard let data = fm.contents(atPath: fileURL.path) else { return nil } // SAFETY: reads validated pulse file

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(InstitutionalPulse.self, from: data)
        } catch {
            Self.logger.warning("Failed to decode pulse \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Loads a specific pulse by week label.
    ///
    /// Delegates to ``loadPulse(label:)`` for backward compatibility.
    ///
    /// - Parameter weekLabel: ISO week label (e.g., "2026-W20").
    /// - Returns: The decoded pulse, or nil if not found or malformed.
    public func loadPulse(weekLabel: String) -> InstitutionalPulse? {
        loadPulse(label: weekLabel)
    }

    // MARK: - Label Date Parsing

    /// Parses a pulse label into a `Date` for chronological sorting.
    ///
    /// Supports two formats:
    /// - `YYYY-MM-DD` (daily date labels) — parsed directly
    /// - `YYYY-WNN` (ISO week labels) — resolved to Monday of that week
    ///
    /// - Returns: The parsed date, or `nil` if the label is not in a recognized format.
    static func parseLabelDate(_ label: String) -> Date? {
        // Try YYYY-MM-DD first
        if label.count == 10, label.dropFirst(4).first == "-", label.dropFirst(7).first == "-" {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.locale = Locale(identifier: "en_US_POSIX")
            if let date = fmt.date(from: label) {
                return date
            }
        }

        // Try YYYY-WNN
        if label.count == 8, label.dropFirst(4).hasPrefix("-W") {
            // silent: invalid week format returns nil
            guard let year = Int(label.prefix(4)),
                  let week = Int(label.suffix(2)),
                  week >= 1, week <= 53 else {
                return nil
            }
            var components = DateComponents()
            components.yearForWeekOfYear = year
            components.weekOfYear = week
            components.weekday = 2 // Monday (1=Sunday in Gregorian)
            components.timeZone = TimeZone(identifier: "UTC")
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            return calendar.date(from: components)
        }

        return nil
    }

    /// Sorts two labels chronologically descending (latest first).
    private static func chronologicalDescending(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDate = parseLabelDate(lhs)
        let rhsDate = parseLabelDate(rhs)
        switch (lhsDate, rhsDate) {
        case let (.some(l), .some(r)):
            return l > r
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs > rhs
        }
    }

    /// Sorts two labels chronologically ascending (earliest first).
    private static func chronologicalAscending(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDate = parseLabelDate(lhs)
        let rhsDate = parseLabelDate(rhs)
        switch (lhsDate, rhsDate) {
        case let (.some(l), .some(r)):
            return l < r
        case (.some, .none):
            return false
        case (.none, .some):
            return true
        case (.none, .none):
            return lhs < rhs
        }
    }
}
