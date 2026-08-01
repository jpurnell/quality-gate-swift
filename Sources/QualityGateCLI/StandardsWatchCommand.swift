import ArgumentParser
import ControlMapping
import Foundation

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

        if drifted {
            print("\nDrift detected — reconcile the affected catalog + mapping and re-stamp. Do NOT trust the mapping until reconciled.")
            throw ExitCode(1)
        }
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
