import ArgumentParser
import Foundation
import QualityGateCore

/// `quality-gate import-swiftlint` — the one-command migration (Phase 4c §1).
///
/// Reads `.swiftlint.yml`, emits a `.quality-gate.yml` fragment: named rules
/// mapped to native equivalents, `custom_rules` translated verbatim to Tier-1
/// `customRules:`, and an honest unmapped report for the tail. The migration
/// tells the truth about its gaps.
struct ImportSwiftLint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-swiftlint",
        abstract: "Translate a .swiftlint.yml into a .quality-gate.yml fragment — mapped, translated, and honestly unmapped."
    )

    @Argument(help: "Path to the SwiftLint config (default: .swiftlint.yml)")
    var path: String = ".swiftlint.yml"

    @Option(name: .long, help: "Write the fragment to this file instead of stdout")
    var output: String?

    func run() throws {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            print("ERROR: no SwiftLint config at \(source.path)")
            throw ExitCode(1)
        }
        let yaml = try String(contentsOf: source, encoding: .utf8)
        let result = try SwiftLintImporter.importConfig(yaml: yaml)

        if let output {
            let destination = URL(fileURLWithPath: output).standardizedFileURL
            try result.fragment.write(to: destination, atomically: true, encoding: .utf8)
            print("Wrote \(destination.path)")
        } else {
            print(result.fragment)
        }

        // The partition, spelled out — one command, no surprises.
        print("Mapped \(result.mapped.count), translated \(result.translated.count) custom rule(s), unmapped \(result.unmapped.count).")
        if !result.unmapped.isEmpty {
            print("Unmapped tail (keep SwiftLint for these, or cover with a custom rule / plugin):")
            for rule in result.unmapped {
                print("  - \(rule)")
            }
        }
    }
}
