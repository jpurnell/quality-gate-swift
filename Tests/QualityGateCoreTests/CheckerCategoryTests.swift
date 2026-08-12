import Foundation
import Testing
@testable import QualityGateCore

/// The editorial grouping, moved out of `README.md` prose and into a type.
@Suite("Checker Category")
struct CheckerCategoryTests {

    @Test("Every case carries the README heading it groups under")
    func headings() {
        #expect(CheckerCategory.correctness.heading == "Correctness")
        #expect(CheckerCategory.safetySecurity.heading == "Safety & Security")
        #expect(CheckerCategory.codeHygiene.heading == "Code Hygiene")
        #expect(CheckerCategory.documentation.heading == "Documentation")
        #expect(CheckerCategory.projectHealth.heading == "Project Health")
        #expect(CheckerCategory.specialty.heading == "Specialty")
    }

    @Test("`allCases` is the README's order, so a generated table cannot silently reorder it")
    func order() {
        #expect(CheckerCategory.allCases.map(\.heading) == [
            "Correctness", "Safety & Security", "Code Hygiene",
            "Documentation", "Project Health", "Specialty",
        ])
    }

    @Test("A heading round-trips back to its case, which is what binds a region to a section")
    func roundTrip() {
        for category in CheckerCategory.allCases {
            #expect(CheckerCategory(heading: category.heading) == category)
        }
        #expect(CheckerCategory(heading: "Not A Section") == nil)
    }

    @Test("The raw value is stable, because configuration and JSON output both encode it")
    func rawValuesAreStable() {
        // Renaming a case is a breaking change to any serialized diagnostic that carries it,
        // so the wire form is pinned here rather than left to whatever the case is called.
        #expect(CheckerCategory.safetySecurity.rawValue == "safety-security")
        #expect(CheckerCategory.projectHealth.rawValue == "project-health")
        #expect(CheckerCategory(rawValue: "correctness") == .correctness)
    }
}
