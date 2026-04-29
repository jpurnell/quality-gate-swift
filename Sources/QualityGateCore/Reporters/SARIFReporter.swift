import Foundation

/// Reports check results in SARIF 2.1.0 format for GitHub Code Scanning.
///
/// SARIF (Static Analysis Results Interchange Format) is an OASIS standard
/// for representing static analysis results.
///
/// Reference: https://sarifweb.azurewebsites.net/
public struct SARIFReporter: Reporter, Sendable {

    /// Creates a new SARIFReporter instance.
    public init() {}

    /// Outputs results in SARIF 2.1.0 format for GitHub Code Scanning.
    ///
    /// - Parameters:
    ///   - results: The check results to report.
    ///   - output: The text stream to write to.
    public func report(_ results: [CheckResult], to output: inout some TextOutputStream) throws {
        let sarif = SARIFDocument(from: results)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(sarif)
        guard let json = String(data: data, encoding: .utf8) else {
            throw QualityGateError.configurationError("Failed to encode SARIF output")
        }

        output.write(json)
        output.write("\n")
    }
}

// MARK: - SARIF 2.1.0 Models

private struct SARIFDocument: Codable {
    let schema: String
    let version: String
    let runs: [Run]

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version
        case runs
    }

    init(from results: [CheckResult]) {
        self.schema = "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json"
        self.version = "2.1.0"

        // Create a single run with all results
        self.runs = [Run(from: results)]
    }

    struct Run: Codable {
        let tool: Tool
        let results: [Result]

        init(from checkResults: [CheckResult]) {
            self.tool = Tool()
            self.results = checkResults.flatMap { checkResult in
                checkResult.diagnostics.map { diagnostic in
                    Result(from: diagnostic, checkerId: checkResult.checkerId)
                }
            }
        }
    }

    struct Tool: Codable {
        let driver: Driver

        init() {
            self.driver = Driver()
        }

        struct Driver: Codable {
            let name: String
            let version: String
            let informationUri: String

            init() {
                self.name = "quality-gate-swift"
                self.version = "1.0.0"
                self.informationUri = "https://github.com/jpurnell/quality-gate-swift"
            }
        }
    }

    struct Result: Codable {
        let ruleId: String
        let level: String
        let message: Message
        let locations: [Location]?

        init(from diagnostic: Diagnostic, checkerId: String) {
            self.ruleId = diagnostic.ruleId ?? "\(checkerId)-violation"
            self.level = Self.mapSeverity(diagnostic.severity)
            self.message = Message(text: diagnostic.message)
            self.locations = Self.makeLocations(from: diagnostic)
        }

        private static func mapSeverity(_ severity: Diagnostic.Severity) -> String {
            switch severity {
            case .error:
                return "error"
            case .warning:
                return "warning"
            case .note:
                return "note"
            }
        }

        private static func makeLocations(from diagnostic: Diagnostic) -> [Location]? {
            guard let file = diagnostic.filePath else {
                return nil
            }

            let physicalLocation = PhysicalLocation(
                artifactLocation: ArtifactLocation(uri: file),
                region: diagnostic.lineNumber.map { line in
                    Region(startLine: line, startColumn: diagnostic.columnNumber)
                }
            )

            return [Location(physicalLocation: physicalLocation)]
        }

        struct Message: Codable {
            let text: String
        }

        struct Location: Codable {
            let physicalLocation: PhysicalLocation
        }

        struct PhysicalLocation: Codable {
            let artifactLocation: ArtifactLocation
            let region: Region?
        }

        struct ArtifactLocation: Codable {
            let uri: String
        }

        struct Region: Codable {
            let startLine: Int
            let startColumn: Int?
        }
    }
}
