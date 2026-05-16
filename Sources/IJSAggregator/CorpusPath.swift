import Foundation
import IJSSensor

/// Computes file paths within the IJS telemetry corpus directory structure.
///
/// All paths follow the convention:
/// `<basePath>/telemetry/<projectID>/YYYY-MM-DD/<HHmmss>_<artifact>.json`
public struct CorpusPath: Sendable, Equatable {
    /// Root of the corpus directory.
    public let basePath: String
    /// Project identifier used in the directory hierarchy.
    public let projectID: String

    /// Creates a new corpus path calculator.
    /// - Parameters:
    ///   - basePath: Root of the corpus directory.
    ///   - projectID: Project identifier used in the directory hierarchy.
    public init(basePath: String, projectID: String) {
        self.basePath = basePath
        self.projectID = projectID
    }

    /// The telemetry root: `<basePath>/telemetry/<projectID>`
    public var projectDirectory: String {
        "\(basePath)/telemetry/\(projectID)"
    }

    /// Daily directory: `<basePath>/telemetry/<projectID>/YYYY-MM-DD`
    public func dailyDirectory(for date: Date) -> String {
        "\(projectDirectory)/\(Self.dayFormatter.string(from: date))"
    }

    /// Metadata artifact path: `<dailyDir>/<HHmmss>_metadata.json`
    public func metadataPath(for timestamp: Date) -> String {
        "\(dailyDirectory(for: timestamp))/\(Self.timeFormatter.string(from: timestamp))_metadata.json"
    }

    /// Calibration artifact path: `<dailyDir>/<HHmmss>_calibration_<index>.json`
    public func calibrationPath(for timestamp: Date, index: Int) -> String {
        "\(dailyDirectory(for: timestamp))/\(Self.timeFormatter.string(from: timestamp))_calibration_\(index).json"
    }

    /// Complexity artifact path: `<dailyDir>/<HHmmss>_complexity.json`
    public func complexityPath(for timestamp: Date) -> String {
        "\(dailyDirectory(for: timestamp))/\(Self.timeFormatter.string(from: timestamp))_complexity.json"
    }

    /// Snapshot directory for a scope: `<basePath>/snapshots/<scope>`
    public func snapshotDirectory(scope: String) -> String {
        "\(basePath)/snapshots/\(scope)"
    }

    /// Snapshot file path: `<basePath>/snapshots/<scope>/YYYY-MM-DD.json`
    public func snapshotPath(scope: String, date: Date) -> String {
        "\(snapshotDirectory(scope: scope))/\(Self.dayFormatter.string(from: date)).json"
    }

    /// Pulse directory for a week: `<basePath>/pulse/<weekLabel>`
    public func pulseDirectory(weekLabel: String) -> String {
        "\(basePath)/pulse/\(weekLabel)"
    }

    /// Pulse file path: `<basePath>/pulse/<weekLabel>/PULSE_<weekLabel>.json`
    public func pulsePath(weekLabel: String) -> String {
        "\(pulseDirectory(weekLabel: weekLabel))/PULSE_\(weekLabel).json"
    }

    /// Pulse root directory: `<basePath>/pulse`
    public var pulseRoot: String {
        "\(basePath)/pulse"
    }

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()
}
