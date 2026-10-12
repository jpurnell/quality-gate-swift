import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// `security.ats-disabled`: App Transport Security exceptions, read from `Info.plist`.
///
/// ATS governs whether cleartext HTTP and weak TLS are *permitted*; switching it off does not
/// turn off certificate validation on an `https` request. So the weakness is CWE-319, not 295.
/// A plist has no comments the serialiser preserves, so the acknowledgement is configuration:
/// `security.atsAllowedInsecureDomains`. There is none for the global key.
///
/// See `TrustHasMoreThanThreeOffSwitches.md` §3.5 and tests 27–34 of §5.
@Suite("ATS policy")
struct ATSPolicyTests {

    private static func plist(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>CFBundleName</key>
        	<string>App</string>
        	<key>NSAppTransportSecurity</key>
        	<dict>
        \(body)
        	</dict>
        </dict>
        </plist>
        """
    }

    private func audit(
        _ text: String,
        configuration: SecurityAuditorConfig = .default
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        ATSPolicy.audit(path: "Info.plist", data: Data(text.utf8), configuration: configuration)
    }

    private func ats(_ result: (diagnostics: [Diagnostic], overrides: [DiagnosticOverride])) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId == "security.ats-disabled" }
    }

    @Test("27. NSAllowsArbitraryLoads true is an error on the key's line")
    func arbitraryLoads() {
        let found = ats(audit(Self.plist("""
            		<key>NSAllowsArbitraryLoads</key>
            		<true/>
            """)))
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.lineNumber == 9)
        #expect(found.first?.filePath == "Info.plist")
        #expect(found.first?.message.contains("[CWE-319]") == true)
    }

    @Test("28. The same plist in binary format is an error with no line")
    func binaryPlist() throws {
        let object: [String: Any] = ["NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true]]
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        let found = ATSPolicy.audit(path: "Info.plist", data: data, configuration: .default)
            .diagnostics.filter { $0.ruleId == "security.ats-disabled" }
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.lineNumber == nil)
    }

    @Test("29. NSAllowsArbitraryLoads false is clean")
    func arbitraryLoadsFalse() {
        let result = audit(Self.plist("""
            		<key>NSAllowsArbitraryLoads</key>
            		<false/>
            """))
        #expect(result.diagnostics.isEmpty)
    }

    @Test("30. NSAllowsLocalNetworking alone is clean")
    func localNetworking() {
        let result = audit(Self.plist("""
            		<key>NSAllowsLocalNetworking</key>
            		<true/>
            """))
        #expect(result.diagnostics.isEmpty)
    }

    /// Apple: on iOS 10 and macOS 10.12 and later, `NSAllowsArbitraryLoads` is ignored when
    /// `NSAllowsLocalNetworking`, `…InWebContent` or `…ForMedia` is present. Still a finding —
    /// it is honoured on older systems and is one deleted key away from being honoured again —
    /// but not the error the bare key is.
    @Test("NSAllowsArbitraryLoads beside a key that overrides it is a warning")
    func arbitraryLoadsOverridden() {
        let found = ats(audit(Self.plist("""
            		<key>NSAllowsArbitraryLoads</key>
            		<true/>
            		<key>NSAllowsLocalNetworking</key>
            		<true/>
            """)))
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("ignored") == true)
    }

    @Test("Arbitrary loads in web content or for media are warnings", arguments: [
        "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia",
    ])
    func scopedArbitraryLoads(key: String) {
        let found = ats(audit(Self.plist("""
            		<key>\(key)</key>
            		<true/>
            """)))
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains(key) == true)
        #expect(found.first?.lineNumber == 9)
    }

    private static let insecureDomain = plist("""
        		<key>NSExceptionDomains</key>
        		<dict>
        			<key>example.com</key>
        			<dict>
        				<key>NSExceptionAllowsInsecureHTTPLoads</key>
        				<true/>
        			</dict>
        		</dict>
        """)

    @Test("31. An exception domain allowing HTTP is a warning naming the domain")
    func insecureDomain() {
        let found = ats(audit(Self.insecureDomain))
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("example.com") == true)
        #expect(found.first?.lineNumber == 13)
    }

    @Test("32. A domain listed in atsAllowedInsecureDomains is recorded as an override")
    func allowedDomain() throws {
        var configuration = SecurityAuditorConfig.default
        configuration.atsAllowedInsecureDomains = ["example.com"]
        let result = audit(Self.insecureDomain, configuration: configuration)
        #expect(ats(result).isEmpty)
        let override = try #require(result.overrides.first { $0.ruleId == "security.ats-disabled" })
        #expect(override.justification.contains("example.com"))
        #expect(override.justification.contains("atsAllowedInsecureDomains"))
        #expect(override.lineNumber == 13)
    }

    @Test("The domain allowance does not reach the global key")
    func allowanceIsNotGlobal() {
        var configuration = SecurityAuditorConfig.default
        configuration.atsAllowedInsecureDomains = ["example.com"]
        let found = ats(audit(Self.plist("""
            		<key>NSAllowsArbitraryLoads</key>
            		<true/>
            """), configuration: configuration))
        #expect(found.count == 1)
    }

    @Test("A minimum TLS version below 1.2 is a warning", arguments: ["TLSv1.0", "TLSv1.1"])
    func weakMinimum(version: String) {
        let found = ats(audit(Self.plist("""
            		<key>NSExceptionDomains</key>
            		<dict>
            			<key>legacy.example.com</key>
            			<dict>
            				<key>NSExceptionMinimumTLSVersion</key>
            				<string>\(version)</string>
            			</dict>
            		</dict>
            """)))
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains(version) == true)
        #expect(found.first?.message.contains("legacy.example.com") == true)
    }

    @Test("A minimum TLS version of 1.2 or 1.3 is clean", arguments: ["TLSv1.2", "TLSv1.3"])
    func adequateMinimum(version: String) {
        let result = audit(Self.plist("""
            		<key>NSExceptionDomains</key>
            		<dict>
            			<key>example.com</key>
            			<dict>
            				<key>NSExceptionMinimumTLSVersion</key>
            				<string>\(version)</string>
            			</dict>
            		</dict>
            """))
        #expect(result.diagnostics.isEmpty)
    }

    @Test("A plist with no ATS dictionary is clean")
    func noATS() {
        let result = audit("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleName</key><string>App</string></dict></plist>
            """)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("33. A malformed plist says it could not be read")
    func malformed() {
        let found = ats(audit("<plist><dict><key>NSAppTransportSecurity</key>"))
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("could not be read") == true)
    }

    @Test("The rule is switched off by enabledRules")
    func disabled() {
        var configuration = SecurityAuditorConfig.default
        configuration.enabledRules = ["security.ssrf"]
        let result = audit(Self.plist("""
            		<key>NSAllowsArbitraryLoads</key>
            		<true/>
            """), configuration: configuration)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("ats-disabled is in the manifest as CWE-319, error, A02:2021")
    func manifestRow() throws {
        let rule = try #require(SecurityRuleManifest.rules.first { $0.ruleId == "security.ats-disabled" })
        #expect(rule.cwes == ["CWE-319"])
        #expect(rule.severity == "ERROR")
        #expect(rule.owaspMobile == "M5 Insecure Communication")
        #expect(rule.owaspTop10 == "A02:2021 Cryptographic Failures")
    }

    @Test("atsAllowedInsecureDomains decodes from configuration")
    func decodes() throws {
        let json = #"{"atsAllowedInsecureDomains": ["legacy.example.com"]}"#
        let config = try JSONDecoder().decode(SecurityAuditorConfig.self, from: Data(json.utf8))
        #expect(config.atsAllowedInsecureDomains == ["legacy.example.com"])
        #expect(SecurityAuditorConfig.default.atsAllowedInsecureDomains == [])
    }

    // MARK: - Through the checker

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-ats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to relative: String, under root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let arbitrary = plist("""
        		<key>NSAllowsArbitraryLoads</key>
        		<true/>
        """)

    @Test("The checker reads an owned Info.plist and reports against it")
    func checkerReadsInfoPlist() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) } // silent: temporary fixture cleanup
        try write(Self.arbitrary, to: "App/Info.plist", under: root)
        try write(Self.arbitrary, to: "App/Widget-Info.plist", under: root)

        var configuration = Configuration()
        configuration.projectRoot = root
        let result = try await SafetyAuditor().check(configuration: configuration)
        let found = result.diagnostics.filter { $0.ruleId == "security.ats-disabled" }
        #expect(found.count == 2)
        #expect(Set(found.compactMap { ($0.filePath as NSString?)?.lastPathComponent })
                == ["Info.plist", "Widget-Info.plist"])
        #expect(result.status == .failed)
    }

    @Test("34. A plist under .build, Pods or Carthage is not read")
    func vendoredTreesSkipped() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) } // silent: temporary fixture cleanup
        for directory in [".build/x", "Pods/Lib", "Carthage/Build/Lib"] {
            try write(Self.arbitrary, to: "\(directory)/Info.plist", under: root)
        }

        var configuration = Configuration()
        configuration.projectRoot = root
        let result = try await SafetyAuditor().check(configuration: configuration)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.ats-disabled" })
    }

    /// Under-including an input serves a stale pass: an edited Info.plist must miss the cache.
    @Test("The safety checker's cache inputs include the Info.plist it reads")
    func cacheInputsIncludePlist() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) } // silent: temporary fixture cleanup
        try write(Self.arbitrary, to: "App/Info.plist", under: root)

        var configuration = Configuration()
        configuration.projectRoot = root
        let inputs = try #require(SafetyAuditor().cacheInputs(configuration: configuration))
        #expect(inputs.files.contains { $0.hasSuffix("App/Info.plist") })
    }
}
