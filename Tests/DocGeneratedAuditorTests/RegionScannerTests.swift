import Foundation
import Testing
@testable import DocGeneratedAuditor

/// The scanner is the whole checker's foundation: everything downstream trusts that a region
/// is exactly the bytes between two delimiters, and that anything it could not pair was
/// reported rather than ignored.
@Suite("Generated Region Scanner")
struct RegionScannerTests {

    // MARK: - Well-formed regions

    @Test("A well-formed region yields its id, both delimiter lines, and the body between them")
    func findsOneRegion() {
        let document = """
        # Title

        <!-- generated:error-registry -->
        | case | meaning |
        | --- | --- |
        <!-- /generated:error-registry -->

        Trailing prose.
        """

        let scan = RegionScanner.scan(document)

        #expect(scan.defects.isEmpty)
        #expect(scan.regions.count == 1)
        #expect(scan.regions.first?.id == "error-registry")
        #expect(scan.regions.first?.openingLine == 3)
        #expect(scan.regions.first?.closingLine == 6)
        #expect(scan.regions.first?.body == "| case | meaning |\n| --- | --- |")
    }

    @Test("An empty region has an empty body, not a newline")
    func emptyRegion() {
        let scan = RegionScanner.scan("""
        <!-- generated:changelog-links -->
        <!-- /generated:changelog-links -->
        """)

        #expect(scan.defects.isEmpty)
        #expect(scan.regions.first?.body == "")
    }

    @Test("A file with no regions reports none, and no defects")
    func noRegions() {
        let scan = RegionScanner.scan("# Just prose\n\nNothing to see.\n")
        #expect(scan.regions.isEmpty)
        #expect(scan.defects.isEmpty)
    }

    @Test("Two distinct regions in one file are both found, in document order")
    func twoRegions() {
        let scan = RegionScanner.scan("""
        <!-- generated:alpha -->
        a
        <!-- /generated:alpha -->
        prose
        <!-- generated:beta -->
        b
        <!-- /generated:beta -->
        """)

        #expect(scan.defects.isEmpty)
        #expect(scan.regions.map(\.id) == ["alpha", "beta"])
    }

    // MARK: - Delimiters own their line

    @Test("A delimiter inside an inline code span is prose about the convention, not a region")
    func inlineCodeSpanIsNotADelimiter() {
        // This exact line appears in the checker's own design proposal. A scanner that read
        // it as a delimiter would report an unterminated region in the document that
        // specifies the format.
        let scan = RegionScanner.scan("- `<!-- generated:no-such-id -->` — an id with no registered generator.\n")
        #expect(scan.regions.isEmpty)
        #expect(scan.defects.isEmpty)
    }

    @Test("A delimiter inside a fenced code block is an example, not a region")
    func fencedDelimiterIsNotARegion() {
        let scan = RegionScanner.scan("""
        Here is the shape:

        ```markdown
        <!-- generated:status-roster -->
        - [x] QualityGateCore
        <!-- /generated:status-roster -->
        ```

        End.
        """)

        #expect(scan.regions.isEmpty)
        #expect(scan.defects.isEmpty)
    }

    @Test("A fenced code block inside a region body does not close the region early")
    func fenceInsideRegionDoesNotCloseEarly() {
        // §11's must-pass case. The region body legitimately contains a fence whose contents
        // look like a delimiter; the region must still end at the real closing line.
        let scan = RegionScanner.scan("""
        <!-- generated:module-structure -->
        ```
        <!-- generated:x -->
        Sources/
        ```
        <!-- /generated:module-structure -->
        """)

        #expect(scan.defects.isEmpty)
        #expect(scan.regions.count == 1)
        #expect(scan.regions.first?.closingLine == 6)
        #expect(scan.regions.first?.body.contains("Sources/") == true)
    }

    // MARK: - Malformed regions are errors, never skips

    @Test("An opening delimiter with no close is reported at the opening line")
    func unterminated() {
        let scan = RegionScanner.scan("""
        prose
        <!-- generated:orphan -->
        body
        """)

        #expect(scan.regions.isEmpty)
        #expect(scan.defects.count == 1)
        #expect(scan.defects.first?.kind == .unterminated)
        #expect(scan.defects.first?.line == 2)
        #expect(scan.defects.first?.ruleId == "doc-generated.region-unterminated")
    }

    @Test("A closing delimiter with no opening is reported at the closing line")
    func unopened() {
        let scan = RegionScanner.scan("prose\n<!-- /generated:orphan -->\n")

        #expect(scan.regions.isEmpty)
        #expect(scan.defects.count == 1)
        #expect(scan.defects.first?.kind == .unopened)
        #expect(scan.defects.first?.line == 2)
    }

    @Test("Two regions with the same id in one file are ambiguous, and reported as such")
    func duplicateID() {
        let scan = RegionScanner.scan("""
        <!-- generated:dup -->
        <!-- /generated:dup -->
        <!-- generated:dup -->
        <!-- /generated:dup -->
        """)

        #expect(scan.defects.contains { $0.kind == .duplicateID && $0.line == 3 })
        #expect(scan.defects.first?.relatedLine == 1)
    }

    @Test("Regions do not nest: an opening inside an open region is a defect")
    func overlapping() {
        let scan = RegionScanner.scan("""
        <!-- generated:outer -->
        <!-- generated:inner -->
        <!-- /generated:inner -->
        <!-- /generated:outer -->
        """)

        #expect(scan.defects.contains { $0.kind == .overlapping && $0.id == "inner" && $0.line == 2 })
    }

    @Test("A closing delimiter naming a different id than the open region is a defect")
    func mismatchedClose() {
        let scan = RegionScanner.scan("""
        <!-- generated:alpha -->
        body
        <!-- /generated:beta -->
        """)

        #expect(scan.defects.contains { $0.kind == .mismatchedClose && $0.id == "beta" && $0.line == 3 })
    }

    @Test("Every defect kind carries a distinct namespaced rule id")
    func ruleIDsAreDistinct() {
        let ids = Set(RegionDefect.Kind.allCases.map {
            RegionDefect(kind: $0, id: "x", line: 1).ruleId
        })
        #expect(ids.count == RegionDefect.Kind.allCases.count)
        #expect(ids.allSatisfy { $0.hasPrefix("doc-generated.") })
    }
}
