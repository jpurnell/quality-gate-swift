import Foundation
import Testing
@testable import ControlMapping

/// Phase 3 polish — Federal Register early warning. Parses the FR API envelope
/// into proposed-rule summaries; only genuine "Proposed Rule" documents count,
/// and the most-recent selector is chronological.
@Suite("FederalRegisterWatch")
struct FederalRegisterWatchTests {

    private let sample = Data("""
    {
      "count": 2,
      "results": [
        {"title": "HIPAA Security Rule To Strengthen the Cybersecurity of ePHI",
         "type": "Proposed Rule", "publication_date": "2025-01-06",
         "document_number": "2024-30983", "html_url": "https://www.federalregister.gov/d/2024-30983"},
        {"title": "Some final rule that merely cites 45 CFR 164",
         "type": "Rule", "publication_date": "2026-01-01",
         "document_number": "2026-00001", "html_url": "https://www.federalregister.gov/d/2026-00001"}
      ]
    }
    """.utf8)

    @Test("parse extracts only Proposed Rule documents")
    func parseProposedOnly() throws {
        let rules = FederalRegisterWatch.parse(sample)
        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        #expect(rule.type == "Proposed Rule")
        #expect(rule.title.contains("HIPAA Security Rule"))
        #expect(rule.publicationDate == "2025-01-06")
        #expect(rule.url == "https://www.federalregister.gov/d/2024-30983")
    }

    @Test("malformed data yields no rules, never throws")
    func parseMalformed() {
        #expect(FederalRegisterWatch.parse(Data("not json".utf8)).isEmpty)
        #expect(FederalRegisterWatch.parse(Data("{}".utf8)).isEmpty)
    }

    @Test("mostRecent picks the latest publication date")
    func mostRecentChronological() throws {
        let rules = [
            ProposedRule(title: "older", type: "Proposed Rule", publicationDate: "2023-04-17", documentNumber: "a", url: "u1"),
            ProposedRule(title: "newer", type: "Proposed Rule", publicationDate: "2025-01-06", documentNumber: "b", url: "u2"),
        ]
        #expect(FederalRegisterWatch.mostRecent(rules)?.title == "newer")
        #expect(FederalRegisterWatch.mostRecent([]) == nil)
    }
}
