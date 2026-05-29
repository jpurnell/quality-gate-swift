import Foundation
import IJSSensor

/// Writes and reads IJS telemetry artifacts as JSON files in the corpus.
///
/// All operations are async to avoid blocking the caller during file I/O.
/// Write operations use a single-writer model — concurrent writes to the
/// same daily directory are safe because filenames include HHmmss timestamps.
public actor TelemetryWriter {

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a new telemetry writer with ISO 8601 date encoding and sorted, pretty-printed JSON.
    public init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Writes a CheckResultMetadata and any JudgmentCalibrations to the corpus.
    ///
    /// Creates the daily directory if it doesn't exist.
    ///
    /// - Throws: `IJSError.telemetryWriteFailed` if directory creation or file write fails.
    public func write(
        metadata: CheckResultMetadata,
        calibrations: [JudgmentCalibration],
        to corpusPath: CorpusPath
    ) async throws {
        let dailyDir = try sanitizedURL(corpusPath.dailyDirectory(for: metadata.timestamp), within: corpusPath.basePath)
        try createDirectoryIfNeeded(at: dailyDir)

        let metadataURL = try sanitizedURL(corpusPath.metadataPath(for: metadata.timestamp), within: corpusPath.basePath)
        try writeJSON(metadata, to: metadataURL)

        if calibrations.count > 1 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, calibration) in calibrations.enumerated() {
                    let url = try sanitizedURL(corpusPath.calibrationPath(for: metadata.timestamp, index: index), within: corpusPath.basePath)
                    let data = try self.encoder.encode(calibration)
                    group.addTask {
                        try data.write(to: url, options: .atomic)
                    }
                }
                try await group.waitForAll()
            }
        } else if let calibration = calibrations.first {
            let url = try sanitizedURL(corpusPath.calibrationPath(for: metadata.timestamp, index: 0), within: corpusPath.basePath)
            try writeJSON(calibration, to: url)
        }
    }

    /// Reads all metadata artifacts for a project within a date range (inclusive).
    ///
    /// Scans daily directories concurrently. Results are sorted by timestamp.
    ///
    /// - Throws: `IJSError.telemetryReadFailed` if deserialization fails.
    public func readMetadata(
        from corpusPath: CorpusPath,
        startDate: Date,
        endDate: Date
    ) async throws -> [CheckResultMetadata] {
        let directories = try dailyDirectoryURLs(in: corpusPath, startDate: startDate, endDate: endDate)
        guard !directories.isEmpty else { return [] }

        let allMetadata = try await withThrowingTaskGroup(
            of: [CheckResultMetadata].self
        ) { group in
            for dir in directories {
                let dec = self.decoder
                group.addTask {
                    try Self.readMetadataFiles(in: dir, decoder: dec)
                }
            }
            var results: [CheckResultMetadata] = []
            for try await batch in group {
                results.append(contentsOf: batch)
            }
            return results
        }

        return allMetadata.sorted { $0.timestamp < $1.timestamp }
    }

    /// Reads all calibration artifacts for a project within a date range (inclusive).
    ///
    /// Daily directories are scanned concurrently. Results are sorted by date.
    ///
    /// - Throws: `IJSError.telemetryReadFailed` if deserialization fails.
    public func readCalibrations(
        from corpusPath: CorpusPath,
        startDate: Date,
        endDate: Date
    ) async throws -> [JudgmentCalibration] {
        let directories = try dailyDirectoryURLs(in: corpusPath, startDate: startDate, endDate: endDate)
        guard !directories.isEmpty else { return [] }

        let allCalibrations = try await withThrowingTaskGroup(
            of: [JudgmentCalibration].self
        ) { group in
            for dir in directories {
                let dec = self.decoder
                group.addTask {
                    try Self.readCalibrationFiles(in: dir, decoder: dec)
                }
            }
            var results: [JudgmentCalibration] = []
            for try await batch in group {
                results.append(contentsOf: batch)
            }
            return results
        }

        return allCalibrations.sorted { $0.date < $1.date }
    }

    // MARK: - Pulse I/O

    /// Writes an InstitutionalPulse to the corpus pulse directory.
    ///
    /// Creates the week directory if needed. Overwrites existing pulse for the same week.
    ///
    /// - Throws: `IJSError.telemetryWriteFailed` if directory creation or write fails.
    public func writePulse(
        _ pulse: InstitutionalPulse,
        to corpusPath: CorpusPath
    ) async throws {
        let weekDir = try sanitizedURL(
            corpusPath.pulseDirectory(weekLabel: pulse.weekLabel),
            within: corpusPath.basePath
        )
        try createDirectoryIfNeeded(at: weekDir)

        let fileURL = try sanitizedURL(
            corpusPath.pulsePath(weekLabel: pulse.weekLabel),
            within: corpusPath.basePath
        )
        try writeJSON(pulse, to: fileURL)
    }

    /// Reads the most recent InstitutionalPulse from the corpus.
    ///
    /// Scans the pulse root directory for week-labeled subdirectories and
    /// returns the pulse from the lexicographically latest one.
    ///
    /// - Returns: The latest pulse, or `nil` if no pulses exist.
    /// - Throws: `IJSError.telemetryReadFailed` if deserialization fails.
    public func readLatestPulse(
        from corpusPath: CorpusPath
    ) async throws -> InstitutionalPulse? {
        let pulseRootURL = URL(fileURLWithPath: corpusPath.pulseRoot)
            .standardized.resolvingSymlinksInPath()
        // SAFETY: Path is resolved via standardized + resolvingSymlinksInPath before use
        guard FileManager.default.fileExists(atPath: pulseRootURL.path) else { return nil }

        let baseURL = URL(fileURLWithPath: corpusPath.basePath)
            .standardized.resolvingSymlinksInPath()

        // silent: best-effort directory listing, returns nil/empty on failure
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: pulseRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        let weekDirs = contents
            .filter { url in
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(baseURL.path) else { return false }
                var isDir: ObjCBool = false
                // SAFETY: Path validated against base via hasPrefix above
                return FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for weekDir in weekDirs {
            let weekLabel = weekDir.lastPathComponent
            let filePath = corpusPath.pulsePath(weekLabel: weekLabel)
            let fileURL = URL(fileURLWithPath: filePath).standardized.resolvingSymlinksInPath()
            guard fileURL.path.hasPrefix(baseURL.path) else { continue }
            // SAFETY: Path validated against base via hasPrefix above
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            do {
                let data = try Data(contentsOf: fileURL)
                return try decoder.decode(InstitutionalPulse.self, from: data)
            } catch {
                throw IJSError.telemetryReadFailed(
                    reason: "Cannot read \(fileURL.path): \(error.localizedDescription)"
                )
            }
        }

        return nil
    }

    // MARK: - Snapshot I/O

    /// Writes a DailySnapshot to the corpus snapshots directory.
    ///
    /// Creates the scope directory if needed. Overwrites existing snapshot for the same date.
    ///
    /// - Throws: `IJSError.telemetryWriteFailed` if directory creation or write fails.
    public func writeSnapshot(
        _ snapshot: DailySnapshot,
        to corpusPath: CorpusPath
    ) async throws {
        let scopeDir = try sanitizedURL(
            corpusPath.snapshotDirectory(scope: snapshot.scope),
            within: corpusPath.basePath
        )
        try createDirectoryIfNeeded(at: scopeDir)

        let fileURL = try sanitizedURL(
            corpusPath.snapshotPath(scope: snapshot.scope, date: snapshot.date),
            within: corpusPath.basePath
        )
        try writeJSON(snapshot, to: fileURL)
    }

    /// Reads all DailySnapshots for a scope within a date range (inclusive).
    ///
    /// - Throws: `IJSError.telemetryReadFailed` if deserialization fails.
    public func readSnapshots(
        from corpusPath: CorpusPath,
        scope: String,
        startDate: Date,
        endDate: Date
    ) async throws -> [DailySnapshot] {
        let scopeDir = URL(fileURLWithPath: corpusPath.snapshotDirectory(scope: scope))
            .standardized.resolvingSymlinksInPath()
        // SAFETY: Path is resolved via standardized + resolvingSymlinksInPath before use
        guard FileManager.default.fileExists(atPath: scopeDir.path) else { return [] }

        let baseURL = URL(fileURLWithPath: corpusPath.basePath)
            .standardized.resolvingSymlinksInPath()

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        let startDay = dayFormatter.string(from: startDate)
        let endDay = dayFormatter.string(from: endDate)

        // silent: best-effort directory listing, returns nil/empty on failure
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: scopeDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        return try files
            .filter { url in
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(baseURL.path) else { return false }
                let name = url.deletingPathExtension().lastPathComponent
                return name >= startDay && name <= endDay
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { fileURL in
                let standardized = fileURL.standardized
                do {
                    let data = try Data(contentsOf: standardized)
                    return try decoder.decode(DailySnapshot.self, from: data)
                } catch {
                    throw IJSError.telemetryReadFailed(
                        reason: "Cannot read \(standardized.path): \(error.localizedDescription)"
                    )
                }
            }
    }

    // MARK: - Complexity Report I/O

    /// Writes a ComplexityReport to the corpus daily directory.
    ///
    /// Creates the daily directory if it doesn't exist.
    ///
    /// - Throws: `IJSError.telemetryWriteFailed` if directory creation or file write fails.
    public func writeComplexityReport(
        _ report: ComplexityReport,
        to corpusPath: CorpusPath
    ) async throws {
        let dailyDir = try sanitizedURL(
            corpusPath.dailyDirectory(for: report.timestamp),
            within: corpusPath.basePath
        )
        try createDirectoryIfNeeded(at: dailyDir)

        let fileURL = try sanitizedURL(
            corpusPath.complexityPath(for: report.timestamp),
            within: corpusPath.basePath
        )
        try writeJSON(report, to: fileURL)
    }

    /// Reads all ComplexityReport artifacts for a project within a date range (inclusive).
    ///
    /// Scans daily directories concurrently. Results are sorted by timestamp.
    ///
    /// - Throws: `IJSError.telemetryReadFailed` if deserialization fails.
    public func readComplexityReports(
        from corpusPath: CorpusPath,
        startDate: Date,
        endDate: Date
    ) async throws -> [ComplexityReport] {
        let directories = try dailyDirectoryURLs(in: corpusPath, startDate: startDate, endDate: endDate)
        guard !directories.isEmpty else { return [] }

        let allReports = try await withThrowingTaskGroup(
            of: [ComplexityReport].self
        ) { group in
            for dir in directories {
                let dec = self.decoder
                group.addTask {
                    try Self.readComplexityFiles(in: dir, decoder: dec)
                }
            }
            var results: [ComplexityReport] = []
            for try await batch in group {
                results.append(contentsOf: batch)
            }
            return results
        }

        return allReports.sorted { $0.timestamp < $1.timestamp }
    }

    /// Writes a quality-gate skip record to the corpus.
    public func writeSkip(
        _ record: SkipRecord,
        to corpusPath: CorpusPath
    ) async throws {
        let dailyDir = try sanitizedURL(
            corpusPath.dailyDirectory(for: record.timestamp),
            within: corpusPath.basePath
        )
        try createDirectoryIfNeeded(at: dailyDir)

        let fileURL = try sanitizedURL(
            corpusPath.skipPath(for: record.timestamp),
            within: corpusPath.basePath
        )
        try writeJSON(record, to: fileURL)
    }

    /// Reads skip records from the corpus within the given date range.
    public func readSkipRecords(
        from corpusPath: CorpusPath,
        startDate: Date,
        endDate: Date
    ) async throws -> [SkipRecord] {
        let directories = try dailyDirectoryURLs(
            in: corpusPath, startDate: startDate, endDate: endDate
        )
        guard !directories.isEmpty else { return [] }

        var records: [SkipRecord] = []
        for dir in directories {
            let files = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasSuffix("_skip.json") }
            for file in files {
                let data = try Data(contentsOf: file)
                let record = try decoder.decode(SkipRecord.self, from: data)
                records.append(record)
            }
        }
        return records.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Path Sanitization

    private func sanitizedURL(_ path: String, within basePath: String) throws -> URL {
        let resolved = URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath()
        let base = URL(fileURLWithPath: basePath).standardized.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base.path) else {
            throw IJSError.telemetryWriteFailed(reason: "Path \(path) escapes corpus base \(basePath)")
        }
        return resolved
    }

    // MARK: - Private Helpers

    private func createDirectoryIfNeeded(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw IJSError.telemetryWriteFailed(reason: "Cannot create directory \(url.path): \(error.localizedDescription)")
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch let error as IJSError {
            throw error
        } catch {
            throw IJSError.telemetryWriteFailed(reason: "Cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    private func dailyDirectoryURLs(
        in corpusPath: CorpusPath,
        startDate: Date,
        endDate: Date
    ) throws -> [URL] {
        let projectURL = URL(fileURLWithPath: corpusPath.projectDirectory).standardized.resolvingSymlinksInPath()
        // SAFETY: Path is resolved via standardized + resolvingSymlinksInPath before use
        guard FileManager.default.fileExists(atPath: projectURL.path) else { return [] }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        let startDay = dayFormatter.string(from: startDate)
        let endDay = dayFormatter.string(from: endDate)

        // silent: best-effort directory listing, returns nil/empty on failure
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        let baseURL = URL(fileURLWithPath: corpusPath.basePath).standardized.resolvingSymlinksInPath()
        return contents
            .filter { url in
                let name = url.lastPathComponent
                return name >= startDay && name <= endDay
            }
            .filter { url in
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(baseURL.path) else { return false }
                var isDir: ObjCBool = false
                // SAFETY: Path validated against base via hasPrefix above
                return FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readMetadataFiles(
        in directory: URL,
        decoder: JSONDecoder
    ) throws -> [CheckResultMetadata] {
        // silent: best-effort directory listing, returns nil/empty on failure
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return try files
            .filter { $0.lastPathComponent.hasSuffix("_metadata.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { fileURL in
                let standardized = fileURL.standardized
                do {
                    let data = try Data(contentsOf: standardized)
                    return try decoder.decode(CheckResultMetadata.self, from: data)
                } catch {
                    throw IJSError.telemetryReadFailed(reason: "Cannot read \(standardized.path): \(error.localizedDescription)")
                }
            }
    }

    private static func readCalibrationFiles(
        in directory: URL,
        decoder: JSONDecoder
    ) throws -> [JudgmentCalibration] {
        // silent: best-effort directory listing, returns nil/empty on failure
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return try files
            .filter { $0.lastPathComponent.contains("_calibration_") && $0.lastPathComponent.hasSuffix(".json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { fileURL in
                let standardized = fileURL.standardized
                do {
                    let data = try Data(contentsOf: standardized)
                    return try decoder.decode(JudgmentCalibration.self, from: data)
                } catch {
                    throw IJSError.telemetryReadFailed(reason: "Cannot read \(standardized.path): \(error.localizedDescription)")
                }
            }
    }

    private static func readComplexityFiles(
        in directory: URL,
        decoder: JSONDecoder
    ) throws -> [ComplexityReport] {
        // silent: best-effort directory listing, returns nil/empty on failure
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return try files
            .filter { $0.lastPathComponent.hasSuffix("_complexity.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { fileURL in
                let standardized = fileURL.standardized
                do {
                    let data = try Data(contentsOf: standardized)
                    return try decoder.decode(ComplexityReport.self, from: data)
                } catch {
                    throw IJSError.telemetryReadFailed(reason: "Cannot read \(standardized.path): \(error.localizedDescription)")
                }
            }
    }
}
