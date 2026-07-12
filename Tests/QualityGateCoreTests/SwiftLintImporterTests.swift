import Foundation
import Testing
@testable import QualityGateCore

/// Phase 4c §1 — `quality-gate import-swiftlint`.
///
/// The contract: rules the config names are mapped to native equivalents
/// where they exist, `custom_rules` translate to 4b Tier-1 `customRules:`
/// verbatim, and the tail lands in an honest unmapped report — the
/// migration is one command and tells the truth about its gaps.
@Suite("SwiftLintImporter")
struct SwiftLintImporterTests {

    // MARK: - Fixtures (real-world shapes: minimal, typical, heavy custom)

    private static let minimal = """
    opt_in_rules:
      - empty_count
    line_length: 140
    """

    private static let typical = """
    disabled_rules:
      - todo
    opt_in_rules:
      - empty_count
      - contains_over_first_not_nil
      - redundant_nil_coalescing
    line_length:
      warning: 120
      error: 200
    file_length: 600
    function_body_length: 60
    function_parameter_count: 6
    nesting:
      type_level: 2
      function_level: 3
    identifier_name:
      min_length: 3
    force_unwrapping: error
    anyobject_protocol: true
    """

    private static let heavyCustom = """
    only_rules:
      - custom_rules
      - trailing_whitespace
    custom_rules:
      no_print:
        regex: 'print\\('
        message: "use os.Logger"
        severity: error
        included: "Sources/.*"
      no_objc_dynamic:
        regex: '@objc dynamic'
        excluded: "Tests/.*"
    """

    // MARK: - Mapping partition

    @Test("minimal: named rules map, nothing invented, nothing unmapped")
    func minimalPartition() throws {
        let result = try SwiftLintImporter.importConfig(yaml: Self.minimal)
        #expect(result.mapped["empty_count"] == "idiom.empty-count")
        #expect(result.mapped["line_length"] == "idiom.line-length")
        #expect(result.unmapped.isEmpty)
        #expect(result.translated.isEmpty)
    }

    @Test("typical: thresholds carry over, disabled rules drop, unknown rules land in the unmapped report")
    func typicalPartition() throws {
        let result = try SwiftLintImporter.importConfig(yaml: Self.typical)
        // Mapped head rules.
        #expect(result.mapped["empty_count"] == "idiom.empty-count")
        #expect(result.mapped["contains_over_first_not_nil"] == "idiom.contains-over-first")
        #expect(result.mapped["force_unwrapping"] == "safety")
        #expect(result.mapped["function_parameter_count"] == "smells")
        // Disabled rules are dropped, not mapped and not unmapped.
        #expect(result.mapped["todo"] == nil)
        #expect(!result.unmapped.contains("todo"))
        // The honest tail.
        #expect(result.unmapped == ["anyobject_protocol"])
        // Thresholds carried into the fragment (warning tier wins).
        #expect(result.fragment.contains("maxLineLength: 120"))
        #expect(result.fragment.contains("maxFileLength: 600"))
        #expect(result.fragment.contains("maxFunctionBodyLength: 60"))
        #expect(result.fragment.contains("maxParameterCount: 6"))
        #expect(result.fragment.contains("minIdentifierLength: 3"))
    }

    @Test("heavy custom: custom_rules translate verbatim to Tier-1 customRules")
    func heavyCustomTranslation() throws {
        let result = try SwiftLintImporter.importConfig(yaml: Self.heavyCustom)
        #expect(result.translated.count == 2)
        let noPrint = try #require(result.translated.first { $0.id == "no_print" })
        #expect(noPrint.pattern == #"print\("#)
        #expect(noPrint.message == "use os.Logger")
        #expect(noPrint.severity == .error)
        #expect(noPrint.include == ["Sources/.*"])
        let noObjc = try #require(result.translated.first { $0.id == "no_objc_dynamic" })
        #expect(noObjc.severity == .warning)
        #expect(noObjc.exclude == ["Tests/.*"])
        #expect(noObjc.message == "no_objc_dynamic")
        // The fragment carries the YAML block.
        #expect(result.fragment.contains("customRules:"))
        #expect(result.fragment.contains("id: no_print"))
        #expect(result.mapped["trailing_whitespace"] == "idiom.trailing-whitespace")
    }

    @Test("the unmapped report is in the fragment as comments, not silently dropped")
    func unmappedReportInFragment() throws {
        let result = try SwiftLintImporter.importConfig(yaml: Self.typical)
        #expect(result.fragment.contains("# Unmapped SwiftLint rules"))
        #expect(result.fragment.contains("#   - anyobject_protocol"))
    }

    @Test("garbage YAML throws rather than emitting an empty fragment")
    func garbageThrows() {
        #expect(throws: (any Error).self) {
            try SwiftLintImporter.importConfig(yaml: "]] not: yaml: [[")
        }
    }
}
