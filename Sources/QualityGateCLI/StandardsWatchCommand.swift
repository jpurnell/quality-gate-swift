import ArgumentParser
import ControlMapping
import Foundation
#if canImport(os)
import os
#endif

/// `quality-gate standards-watch` — detect upstream drift in the compliance
/// control catalogs (RegulatoryControlMapping Phase 3).
///
/// **Detect and alert only.** It never edits a catalog: a human reconciles and
/// re-stamps. HIPAA (eCFR) is fetched and hashed against the last-observed
/// value; SOC 2 / ISO are copyrighted and not machine-readable, so they surface
/// as manual-review. Runs as scheduled network I/O — never in the gate's
/// enforcement path. Exits non-zero if any catalog has drifted, so a cron job
/// can alert.
struct StandardsWatchCommand: AsyncParsableCommand {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "StandardsWatch")
    static let configuration = CommandConfiguration(
        commandName: "standards-watch",
        abstract: "Detect upstream drift in the SOC2/ISO/HIPAA control catalogs (detect + alert only). Exits non-zero on drift."
    )

    func run() async throws {
        let catalogs = ControlMappingResources.catalogs()
        guard !catalogs.isEmpty else {
            print("No control catalogs are bundled — nothing to watch.")
            return
        }

        let results = await StandardsWatch.run(catalogs: catalogs, source: ECFRStandardsSource())

        print("Standards Watch — upstream drift detection (detect + alert only; a human reconciles).")
        var drifted = false
        for result in results.sorted(by: { $0.framework < $1.framework }) {
            let tag: String
            switch result.state {
            case .drifted: tag = "DRIFTED"; drifted = true
            case .unchanged: tag = "unchanged"
            case .seeded: tag = "seeded"
            case .manualReviewOnly: tag = "manual"
            case .unreachable: tag = "unreachable"
            }
            print("  [\(tag)] \(result.framework) — \(result.detail)")
        }

        // Early warning: proposed changes on the Federal Register touching HIPAA
        // (45 CFR 164) — a heads-up before the eCFR text itself changes.
        if catalogs.contains(where: { $0.source == "ecfr" }) {
            let proposed = await Self.federalRegisterProposedRules()
            if let latest = FederalRegisterWatch.mostRecent(proposed) {
                print("\nProposed changes (Federal Register, 45 CFR 164): \(proposed.count) on record.")
                print("  latest: \(latest.publicationDate) — \(latest.title)")
                print("  \(latest.url)")
                print("  Not yet in effect until finalized — review whether it will affect the mapping.")
            }
        }

        if drifted {
            print("\nDrift detected — reconcile the affected catalog + mapping and re-stamp. Do NOT trust the mapping until reconciled.")
            throw ExitCode(1)
        }
    }

    /// Recent proposed rules touching 45 CFR 164 from the Federal Register API.
    /// Advisory only — returns [] on any failure, and the host is allow-listed.
    static func federalRegisterProposedRules() async -> [ProposedRule] {
        guard var components = URLComponents(string: "https://www.federalregister.gov/api/v1/documents.json") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "conditions[cfr][title]", value: "45"),
            URLQueryItem(name: "conditions[cfr][part]", value: "164"),
            URLQueryItem(name: "conditions[type][]", value: "PRORULE"),
            URLQueryItem(name: "per_page", value: "10"),
            URLQueryItem(name: "order", value: "newest"),
            URLQueryItem(name: "fields[]", value: "title"),
            URLQueryItem(name: "fields[]", value: "type"),
            URLQueryItem(name: "fields[]", value: "publication_date"),
            URLQueryItem(name: "fields[]", value: "document_number"),
            URLQueryItem(name: "fields[]", value: "html_url"),
        ]
        guard let url = components.url, url.host == "www.federalregister.gov" else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Advisory, but an omitted early-warning line and "nothing is changing" look
        // identical to the reader, and only one of them is true.
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            Self.logger.warning(
                "standards watch could not reach the Federal Register; omitting the early-warning line, which is not the same as there being no warning: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return FederalRegisterWatch.parse(data)
    }
}

/// Fetches the current upstream text for eCFR-sourced catalogs; returns nil for
/// copyrighted sources (SOC 2 / ISO).
///
/// The catalog's `sourceRef` is an eCFR versioner-API URL containing a `{date}`
/// placeholder, which this adapter fills with today's UTC date. The versioner
/// returns the regulation *as of that date* with the date normalized out of the
/// content (`_SUBSTITUTE_DATE_`) — so the hash is stable day-to-day but changes
/// when the rule is actually amended, which is exactly the drift signal.
struct ECFRStandardsSource: StandardsSource {
    /// Hosts this source is permitted to fetch — an SSRF allow-list. The
    /// `sourceRef` is tool-bundled data, not user input, but the host is
    /// constrained anyway so a bad catalog entry can never redirect the fetch.
    static let allowedHosts: Set<String> = ["www.ecfr.gov"]

    func fetchUpstream(for catalog: ControlCatalog) async throws -> String? {
        guard catalog.source == "ecfr" else { return nil }
        let resolved = catalog.sourceRef.replacingOccurrences(of: "{date}", with: Self.todayUTC())
        // SECURITY: URL is built from tool-bundled catalog data and the host is allow-listed to eCFR — not attacker-controllable (CWE-918 mitigated).
        guard let url = URL(string: resolved), let host = url.host, Self.allowedHosts.contains(host) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8)
    }

    /// Today's date as `YYYY-MM-DD` in UTC — the versioner requires a date.
    static func todayUTC() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter.string(from: Date())
    }
}
