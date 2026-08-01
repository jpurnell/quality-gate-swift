import Foundation

/// A proposed rule on the Federal Register that touches a watched regulation —
/// an early warning that a standard may change before the eCFR text does.
public struct ProposedRule: Sendable, Codable, Equatable {
    /// The rule's title.
    public let title: String
    /// The document type as reported by the Federal Register (e.g. "Proposed Rule").
    public let type: String
    /// ISO `YYYY-MM-DD` publication date.
    public let publicationDate: String
    /// The Federal Register document number.
    public let documentNumber: String
    /// Canonical URL for the document.
    public let url: String

    /// Creates a proposed-rule summary.
    public init(title: String, type: String, publicationDate: String, documentNumber: String, url: String) {
        self.title = title
        self.type = type
        self.publicationDate = publicationDate
        self.documentNumber = documentNumber
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case title, type
        case publicationDate = "publication_date"
        case documentNumber = "document_number"
        case url = "html_url"
    }
}

/// Parses Federal Register API responses into proposed-rule summaries — the
/// early-warning half of `standards-watch`. Pure over its input (the network
/// lives in the CLI adapter), so it is fully unit-tested.
public enum FederalRegisterWatch {

    /// The `documents.json` envelope shape we consume.
    private struct Response: Codable {
        let results: [ProposedRule]
    }

    /// Every genuine proposed rule in a Federal Register `documents.json`
    /// response. Non-proposed documents (final rules that merely cite the part)
    /// are dropped; a malformed response yields an empty list, never a throw.
    public static func parse(_ data: Data) -> [ProposedRule] {
        // silent: a malformed FR response yields no early warnings; the watch reports "none"
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return response.results.filter { $0.type == "Proposed Rule" }
    }

    /// The most recently published rule, or nil if there are none.
    public static func mostRecent(_ rules: [ProposedRule]) -> ProposedRule? {
        rules.max(by: { $0.publicationDate < $1.publicationDate })
    }
}
