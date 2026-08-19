import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// The README's checker reference, derived from the registry that decides what actually runs.
@Suite("Checker Table Generator")
struct CheckerTableGeneratorTests {

    /// A registry shaped like the real one: a literal array, comments between entries, some
    /// checkers constructed with arguments, and two appended conditionally rather than listed.
    private static let registry = """
    import QualityGateCore

    enum QualityGateCLI {
        static func checkerRegistry(configuration: Configuration) -> [any QualityChecker] {
            return [
                Alpha(),
                // A comment between entries, which the parser must step over.
                Beta(config: configuration.beta),
                Gamma()
            ] + configuration.plugins.map { PluginChecker(plugin: $0) as any QualityChecker }
            + (configuration.customRules.isEmpty ? [] : [CustomRulesChecker()])
        }
    }
    """

    private static func checker(
        _ type: String, id: String, summary: String, category: String
    ) -> String {
        """
        import QualityGateCore

        public struct \(type): QualityChecker, Sendable {
            public let id = "\(id)"
            public let name = "\(type)"
            public let summary = "\(summary)"
            public let category = CheckerCategory.\(category)
            let kind = CheckerKind.code
            let effect = CheckerEffect.readOnly
            let executesProjectCode = false

            public func check(configuration: Configuration) async throws -> CheckResult {
                CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
            }
        }
        """
    }

    private static func project() throws -> URL {
        try TemporaryDocProject.make(extras: [
            "Sources/QualityGateCLI/QualityGateCLI.swift": registry,
            "Sources/AlphaAuditor/Alpha.swift": checker(
                "Alpha", id: "alpha", summary: "Things Alpha finds", category: "correctness"),
            "Sources/BetaAuditor/Beta.swift": checker(
                "Beta", id: "beta", summary: "Things Beta finds", category: "correctness"),
            "Sources/GammaAuditor/Gamma.swift": checker(
                "Gamma", id: "gamma", summary: "Things Gamma finds", category: "specialty"),
        ])
    }

    @Test("Identity: one generator per category, and the id carries the category")
    func identity() {
        let generator = CheckerTableGenerator(category: .safetySecurity)
        #expect(generator.id == "checker-table-safety-security")
        #expect(generator.derivedFrom.contains("checkerRegistry"))
    }

    @Test("Every category has a registered generator, or a section governs nothing")
    func everyCategoryIsRegistered() {
        for category in CheckerCategory.allCases {
            let id = "checker-table-\(category.rawValue)"
            #expect(RegionGeneratorRegistry.generator(for: id)?.id == id)
        }
    }

    @Test("One row per registered checker in this category, in registry order")
    func rowsForCategory() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try CheckerTableGenerator(category: .correctness).generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        #expect(body.lines == [
            "| `alpha` | AlphaAuditor | Things Alpha finds |",
            "| `beta` | BetaAuditor | Things Beta finds |",
        ])
    }

    @Test("A checker in another category does not appear in this one's table")
    func categoriesDoNotBleed() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let correctness = try CheckerTableGenerator(category: .correctness).generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())
        let specialty = try CheckerTableGenerator(category: .specialty).generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        #expect(!correctness.contains("gamma"))
        #expect(specialty.lines == ["| `gamma` | GammaAuditor | Things Gamma finds |"])
    }

    @Test("The module column is the directory under Sources/, not the type's name")
    func moduleColumn() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try CheckerTableGenerator(category: .correctness).generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        // `Alpha` is declared in `Sources/AlphaAuditor/Alpha.swift`. A generator that printed
        // the type name would document a module that does not exist.
        #expect(body.contains("| AlphaAuditor |"))
        #expect(!body.contains("| Alpha |"))
    }

    @Test("A conditionally appended checker is not in the literal, so it is not documented")
    func conditionalCheckersAreNotDocumented() throws {
        // `PluginChecker` and `CustomRulesChecker` exist only when a project configures them.
        // Documenting them as shipped checkers would describe a package nobody has.
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        for category in CheckerCategory.allCases {
            let body = try CheckerTableGenerator(category: category).generate(
                projectRoot: root, currentBody: "",
                configuration: TemporaryDocProject.configuration())
            #expect(!body.contains("PluginChecker"))
            #expect(!body.contains("CustomRulesChecker"))
        }
    }

    @Test("A category with no registered checker generates an empty table, not a throw")
    func emptyCategory() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try CheckerTableGenerator(category: .documentation).generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        #expect(body.isEmpty)
    }

    @Test("An empty summary gets a visible placeholder rather than an empty cell")
    func emptySummaryIsVisible() throws {
        let root = try TemporaryDocProject.make(extras: [
            "Sources/QualityGateCLI/QualityGateCLI.swift": Self.registry,
            "Sources/AlphaAuditor/Alpha.swift": Self.checker(
                "Alpha", id: "alpha", summary: "", category: "correctness"),
            "Sources/BetaAuditor/Beta.swift": Self.checker(
                "Beta", id: "beta", summary: "Things Beta finds", category: "correctness"),
            "Sources/GammaAuditor/Gamma.swift": Self.checker(
                "Gamma", id: "gamma", summary: "Things Gamma finds", category: "specialty"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try CheckerTableGenerator(category: .correctness).generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        #expect(body.contains("needs a `summary`"))
    }

    @Test("No registry file is ungeneratable — an empty table is not the same claim")
    func absentRegistryThrows() throws {
        let root = try TemporaryDocProject.make(readme: "# Readme\n")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: RegionGeneratorError.self) {
            try CheckerTableGenerator(category: .correctness).generate(
                projectRoot: root, currentBody: "",
                configuration: TemporaryDocProject.configuration())
        }
    }

    @Test("A registered type whose source is missing is reported, never silently dropped")
    func unresolvableCheckerThrows() throws {
        // `Beta` and `Gamma` are in the registry with no source anywhere. Skipping them would
        // shorten the table silently, which is the one failure a generated table must not have.
        let root = try TemporaryDocProject.make(extras: [
            "Sources/QualityGateCLI/QualityGateCLI.swift": Self.registry,
            "Sources/AlphaAuditor/Alpha.swift": Self.checker(
                "Alpha", id: "alpha", summary: "Things Alpha finds", category: "correctness"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: RegionGeneratorError.self) {
            try CheckerTableGenerator(category: .correctness).generate(
                projectRoot: root, currentBody: "",
                configuration: TemporaryDocProject.configuration())
        }
    }

    @Test("The current body is ignored: every column is derived")
    func currentBodyIsIgnored() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let generator = CheckerTableGenerator(category: .correctness)
        let configuration = TemporaryDocProject.configuration()
        let fromEmpty = try generator.generate(
            projectRoot: root, currentBody: "", configuration: configuration)
        let fromStale = try generator.generate(
            projectRoot: root, currentBody: "| `nonsense` | Nowhere | invented |",
            configuration: configuration)

        #expect(fromEmpty == fromStale)
    }
}
