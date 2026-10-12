import Foundation
import QualityGateCore
import QualityGateLogging

/// `security.ats-disabled`: App Transport Security exceptions in an `Info.plist`.
///
/// | Key under `NSAppTransportSecurity`, when set | Severity |
/// |---|---|
/// | `NSAllowsArbitraryLoads` `true` | error |
/// | … beside `NSAllowsLocalNetworking`, `…InWebContent` or `…ForMedia`, which make the OS ignore it | warning |
/// | `NSAllowsArbitraryLoadsInWebContent` / `NSAllowsArbitraryLoadsForMedia` `true` | warning |
/// | `NSExceptionDomains › <domain> › NSExceptionAllowsInsecureHTTPLoads` `true` | warning, names the domain |
/// | `NSExceptionDomains › <domain> › NSExceptionMinimumTLSVersion` below `TLSv1.2` | warning |
///
/// `NSAllowsLocalNetworking` alone is not reported. Key names and the `TLSv1.0`…`TLSv1.3` values
/// were read from Apple's Information Property List reference on 2026-10-02.
///
/// The CWE is 319, not 295. ATS governs whether cleartext HTTP and weak TLS are *permitted*;
/// disabling it does not turn off certificate validation on an `https` request, and tagging it
/// 295 would claim something the key does not do.
///
/// Not a `SyntaxVisitor`: a property list is a dictionary, read the way `privacy-manifest` reads
/// one — `PropertyListSerialization`, which handles XML and binary alike. Values come back
/// without positions, so for an XML plist the line is found by searching the text for the key;
/// a binary plist's finding has a file and no line, and is still a finding.
enum ATSPolicy {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "ATSPolicy")

    static let ruleId = "security.ats-disabled"

    /// Keys whose presence makes iOS 10+ and macOS 10.12+ ignore `NSAllowsArbitraryLoads`.
    private static let overridingKeys = [
        "NSAllowsArbitraryLoadsForMedia", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsLocalNetworking",
    ]

    private static let weakMinimumVersions: Set<String> = ["TLSv1.0", "TLSv1.1"]

    /// Findings and recorded allowances for one property list.
    ///
    /// - Parameters:
    ///   - path: The file, used as every diagnostic's `filePath`.
    ///   - data: Its bytes, XML or binary.
    ///   - configuration: Security configuration — `enabledRules` and `atsAllowedInsecureDomains`.
    /// - Returns: Diagnostics, and an override for each allowed insecure domain.
    static func audit(
        path: String,
        data: Data,
        configuration: SecurityAuditorConfig
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        guard configuration.enabledRules.isEmpty || configuration.enabledRules.contains(ruleId) else {
            return ([], [])
        }

        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            // Never silently clean: an unreadable plist is unexamined, and says so — in the
            // report for whoever reads it, and in the log for whoever is running the gate.
            logger.warning("Could not parse property list \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ([Diagnostic(
                severity: .warning,
                message: "Property list could not be read, so its App Transport Security settings "
                    + "were not examined: \(error.localizedDescription)",
                filePath: path,
                ruleId: ruleId,
                suggestedFix: "Fix the property list so it parses.")], [])
        }
        guard let root = object as? [String: Any],
              let ats = root["NSAppTransportSecurity"] as? [String: Any] else { return ([], []) }

        let locator = KeyLocator(data: data)
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        if ats["NSAllowsArbitraryLoads"] as? Bool == true {
            let overriding = overridingKeys.filter { ats[$0] != nil }
            if overriding.isEmpty {
                diagnostics.append(finding(
                    .error, path: path, line: locator.line(of: "NSAllowsArbitraryLoads"),
                    "NSAllowsArbitraryLoads is true: App Transport Security is disabled for every "
                        + "connection the app makes, so cleartext HTTP is permitted anywhere.",
                    fix: "Remove the key, and add an NSExceptionDomains entry for each host that "
                        + "genuinely cannot serve HTTPS."))
            } else {
                diagnostics.append(finding(
                    .warning, path: path, line: locator.line(of: "NSAllowsArbitraryLoads"),
                    "NSAllowsArbitraryLoads is true. It is ignored on iOS 10 and macOS 10.12 and later "
                        + "because \(overriding.joined(separator: ", ")) is present, and honoured on "
                        + "anything older or once that key is removed.",
                    fix: "Remove NSAllowsArbitraryLoads."))
            }
        }

        for key in ["NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia"]
            where ats[key] as? Bool == true {
            diagnostics.append(finding(
                .warning, path: path, line: locator.line(of: key),
                "\(key) is true: App Transport Security is disabled for "
                    + (key.hasSuffix("WebContent") ? "web views." : "AV Foundation media loads."),
                fix: "Remove the key unless the app must display arbitrary third-party content."))
        }

        let domains = ats["NSExceptionDomains"] as? [String: Any] ?? [:]
        for (domain, value) in domains.sorted(by: { $0.key < $1.key }) {
            guard let settings = value as? [String: Any] else { continue }
            if settings["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true {
                let line = locator.line(of: "NSExceptionAllowsInsecureHTTPLoads", after: domain)
                if configuration.atsAllowedInsecureDomains.contains(domain) {
                    overrides.append(DiagnosticOverride(
                        ruleId: ruleId,
                        justification: "\(domain) is listed in security.atsAllowedInsecureDomains",
                        filePath: path,
                        lineNumber: line))
                } else {
                    diagnostics.append(finding(
                        .warning, path: path, line: line,
                        "Cleartext HTTP is allowed to \(domain) by NSExceptionAllowsInsecureHTTPLoads.",
                        fix: "Serve \(domain) over HTTPS, or list it in security.atsAllowedInsecureDomains "
                            + "with the reason recorded beside it."))
                }
            }
            if let version = settings["NSExceptionMinimumTLSVersion"] as? String,
               weakMinimumVersions.contains(version) {
                diagnostics.append(finding(
                    .warning, path: path,
                    line: locator.line(of: "NSExceptionMinimumTLSVersion", after: domain),
                    "NSExceptionMinimumTLSVersion for \(domain) is \(version), below the TLSv1.2 default.",
                    fix: "Remove the key, or raise it to TLSv1.2."))
            }
        }
        return (diagnostics, overrides)
    }

    private static func finding(
        _ severity: Diagnostic.Severity,
        path: String,
        line: Int?,
        _ message: String,
        fix: String
    ) -> Diagnostic {
        Diagnostic(
            severity: severity,
            message: message + " " + (SecurityRuleManifest.cwe(for: ruleId).map { "[\($0)]" } ?? ""),
            filePath: path,
            lineNumber: line,
            ruleId: ruleId,
            suggestedFix: fix)
    }
}

/// Finds the line of a `<key>` in an XML property list's text.
///
/// `nil` for a binary plist, and for a key that is not found — a finding without a line rather
/// than a finding on the wrong one.
private struct KeyLocator {
    private let lines: [String]

    init(data: Data) {
        let text = String(data: data, encoding: .utf8) ?? ""
        lines = text.hasPrefix("bplist") ? [] : text.lines
    }

    /// The 1-based line of `<key>name</key>`, searching after the line of `<key>anchor</key>`
    /// when an anchor is given.
    func line(of name: String, after anchor: String? = nil) -> Int? {
        var start = 0
        if let anchor {
            guard let anchorIndex = index(of: anchor, from: 0) else { return nil }
            start = anchorIndex + 1
        }
        return index(of: name, from: start).map { $0 + 1 }
    }

    private func index(of key: String, from start: Int) -> Int? {
        guard start < lines.count else { return nil }
        let needle = "<key>\(key)</key>"
        return lines[start...].firstIndex { $0.contains(needle) }
    }
}
